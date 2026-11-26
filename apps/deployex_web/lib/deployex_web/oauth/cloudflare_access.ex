defmodule DeployexWeb.OAuth.CloudflareAccess do
  @moduledoc """
  Signs a user in from the identity that Cloudflare Access puts on every request.

  With DeployEx behind [Cloudflare Access](https://developers.cloudflare.com/cloudflare-one/),
  a request only arrives after Cloudflare has signed the user in with the identity provider
  of the team, and it carries a signed token, the `Cf-Access-Jwt-Assertion` header. There
  is no login page and no password: the token is the sign-in.

  ## What is checked

    * the signature, with the public keys of the team, read from
      `https://<team_domain>/cdn-cgi/access/certs` and kept for an hour
    * `iss`, which has to be the team, and `aud`, which has to hold the `audience` of the
      Access application DeployEx is behind. Without it a token made for another
      application of the same team would be taken
    * `exp`

  A request that does not come through Cloudflare has no token, and one cannot be made
  without the private key of the team. The built-in password login is still there for it,
  a port-forward for instance.

  ## The role

  An email on the lists of the `auth` section has the role they give it, see
  `DeployexWeb.OAuth.Allowlist`. With `admin_groups` or `read_only_groups` set, the groups
  of the user are read from `https://<team_domain>/cdn-cgi/access/get-identity`, which
  answers with what the identity provider says of the user, and a user in one of them has
  that role. Admin wins over read-only, and a user with neither is not signed in.

  ## What is kept

  Nothing on the server. The email, the role and when the token expires go in the session
  cookie, which DeployEx signs, so a LiveView does not need the header and any DeployEx
  with the same secret takes it. It is made again when the token or the `auth` section
  changes, which is also when the groups are read again.
  """

  require Logger

  alias DeployexWeb.OAuth.Allowlist
  alias DeployexWeb.OAuth.Config

  @header "cf-access-jwt-assertion"
  @session_key "cloudflare_access"
  @keys_ttl_ms :timer.hours(1)
  # Keys that do not verify a token are read again, a new key for instance, and not more often
  @keys_retry_ms :timer.seconds(30)

  @type identity :: %{email: String.t(), role: :admin | :read_only}

  defmodule Http do
    @moduledoc """
    The two requests to Cloudflare, in one place so a test can answer for them.
    """

    @callback get_json(url :: String.t(), headers :: [{String.t(), String.t()}]) ::
                {:ok, term()} | {:error, term()}

    @behaviour __MODULE__

    @impl true
    def get_json(url, headers) do
      request = Finch.build(:get, url, headers)

      with {:ok, %Finch.Response{status: 200, body: body}} <-
             Finch.request(request, DeployexWeb.Finch, receive_timeout: 5_000),
           {:ok, json} <- Jason.decode(body) do
        {:ok, json}
      else
        {:ok, %Finch.Response{status: status}} -> {:error, {:status, status}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  ### ==========================================================================
  ### Public APIs
  ### ==========================================================================

  @doc """
  Whether the `auth` section asks for Cloudflare Access and has what it needs.
  """
  @spec configured?() :: boolean()
  def configured? do
    Config.provider_module() == __MODULE__ and present?(Config.team_domain()) and
      present?(Config.audience())
  end

  @doc """
  The name of the session key that holds the identity.
  """
  @spec session_key() :: String.t()
  def session_key, do: @session_key

  @doc """
  Signs in the user of the request, from its Cloudflare Access token.

  Returns the conn, with the identity in its session, and the user, or `nil` when
  Cloudflare Access is not configured, the request has no token, the token is not valid or
  the user has no role.
  """
  @spec authenticate(Plug.Conn.t()) :: {Plug.Conn.t(), identity() | nil}
  def authenticate(conn) do
    with true <- configured?(),
         [token] <- Plug.Conn.get_req_header(conn, @header),
         {:ok, claims} <- verify(token) do
      stamp = stamp(token)
      config = config_stamp()

      case Plug.Conn.get_session(conn, @session_key) do
        # The same token and the same auth section: the role was worked out already
        %{"stamp" => ^stamp, "config" => ^config, "email" => email, "role" => role} ->
          {conn, %{email: email, role: String.to_existing_atom(role)}}

        _other ->
          sign_in(conn, token, claims, stamp)
      end
    else
      _not_signed_in -> {Plug.Conn.delete_session(conn, @session_key), nil}
    end
  end

  @doc """
  The user of a session that `authenticate/1` made, for a LiveView, which has no header.

  It is `nil` once the token has expired or the `auth` section has changed: the next
  request, a reload of the page, signs the user in again.
  """
  @spec user_from_session(map()) :: identity() | nil
  def user_from_session(%{@session_key => %{"email" => email, "role" => role} = identity}) do
    with true <- configured?(),
         true <- identity["exp"] > System.system_time(:second),
         true <- identity["config"] == config_stamp() do
      %{email: email, role: String.to_existing_atom(role)}
    else
      _expired -> nil
    end
  end

  def user_from_session(_session), do: nil

  @doc """
  Verifies a Cloudflare Access token: its signature, issuer, audience and expiry.
  """
  @spec verify(String.t()) :: {:ok, map()} | {:error, term()}
  def verify(token) do
    with {:ok, claims} <- verify_signature(token),
         :ok <- verify_claims(claims) do
      {:ok, claims}
    end
  end

  ### ==========================================================================
  ### Private functions
  ### ==========================================================================

  defp sign_in(conn, token, %{"email" => email, "exp" => exp}, stamp) when is_binary(email) do
    case role(email, token) do
      role when role in [:admin, :read_only] ->
        identity = %{
          "email" => email,
          "role" => Atom.to_string(role),
          "exp" => exp,
          "stamp" => stamp,
          "config" => config_stamp()
        }

        {Plug.Conn.put_session(conn, @session_key, identity), %{email: email, role: role}}

      :denied ->
        Logger.warning("Cloudflare Access user #{email} has no role in the auth section")
        {Plug.Conn.delete_session(conn, @session_key), nil}
    end
  end

  # A service token has no email, and no role here
  defp sign_in(conn, _token, _claims, _stamp),
    do: {Plug.Conn.delete_session(conn, @session_key), nil}

  # The lists of emails first, they need no request. The groups are only read when the
  # auth section has groups and the email is not an admin already
  defp role(email, token) do
    allowlist = Config.allowlist()
    by_email = Allowlist.role(email, allowlist)
    admin_groups = Map.get(allowlist, :admin_groups, [])
    read_only_groups = Map.get(allowlist, :read_only_groups, [])

    if by_email == :admin or (admin_groups == [] and read_only_groups == []) do
      by_email
    else
      groups = groups(token)

      cond do
        Enum.any?(groups, &(&1 in admin_groups)) -> :admin
        by_email == :read_only or Enum.any?(groups, &(&1 in read_only_groups)) -> :read_only
        true -> :denied
      end
    end
  end

  # What the identity provider says of the user. A group is its name, or a map with one
  defp groups(token) do
    url = "https://#{Config.team_domain()}/cdn-cgi/access/get-identity"

    case http().get_json(url, [{"cookie", "CF_Authorization=#{token}"}]) do
      {:ok, %{"groups" => groups}} when is_list(groups) ->
        Enum.flat_map(groups, fn
          group when is_binary(group) -> [group]
          %{"name" => name} when is_binary(name) -> [name]
          _other -> []
        end)

      other ->
        Logger.warning(
          "The groups of a Cloudflare Access user could not be read: #{inspect(other)}"
        )

        []
    end
  end

  defp verify_signature(token) do
    case verify_with(keys(), token) do
      {:ok, claims} ->
        {:ok, claims}

      :error ->
        # The team may have a new key
        case verify_with(keys(:refresh), token) do
          {:ok, claims} -> {:ok, claims}
          :error -> {:error, :invalid_signature}
        end
    end
  end

  defp verify_with(keys, token) do
    Enum.find_value(keys, :error, fn key ->
      case JOSE.JWT.verify_strict(key, ["RS256"], token) do
        {true, %JOSE.JWT{fields: claims}, _jws} -> {:ok, claims}
        _not_this_key -> nil
      end
    end)
  rescue
    # What is not a token at all
    _error -> :error
  end

  defp verify_claims(claims) do
    cond do
      claims["iss"] != "https://#{Config.team_domain()}" -> {:error, :invalid_issuer}
      Config.audience() not in List.wrap(claims["aud"]) -> {:error, :invalid_audience}
      not is_integer(claims["exp"]) -> {:error, :no_expiry}
      claims["exp"] <= System.system_time(:second) -> {:error, :expired}
      true -> :ok
    end
  end

  # The keys of the team, kept for an hour. With :refresh they are read again, when the
  # last read is not too recent
  defp keys(refresh \\ nil) do
    domain = Config.team_domain()
    now = System.monotonic_time(:millisecond)

    case :persistent_term.get({__MODULE__, :keys}, nil) do
      {^domain, keys, read_at}
      when (refresh == nil and now - read_at < @keys_ttl_ms) or now - read_at < @keys_retry_ms ->
        keys

      kept ->
        read_keys(domain, now, kept)
    end
  end

  defp read_keys(domain, now, kept) do
    with {:ok, %{"keys" => keys}} when is_list(keys) <-
           http().get_json("https://#{domain}/cdn-cgi/access/certs", []),
         {:ok, keys} <- jwks(keys) do
      :persistent_term.put({__MODULE__, :keys}, {domain, keys, now})
      keys
    else
      other ->
        Logger.warning("The keys of Cloudflare Access could not be read: #{inspect(other)}")

        # The keys it had still verify what they signed. The timestamp is kept current
        # either way, so a read that keeps failing is retried at @keys_retry_ms and not
        # on every request
        keys =
          case kept do
            {^domain, keys, _read_at} -> keys
            _none -> []
          end

        :persistent_term.put({__MODULE__, :keys}, {domain, keys, now})
        keys
    end
  end

  # A key Cloudflare never sends, but the shape JOSE.JWK.from_map/1 raises instead of
  # erroring on is not guaranteed to never arrive, e.g. during an incident on their side
  defp jwks(keys) do
    {:ok, Enum.map(keys, &JOSE.JWK.from_map/1)}
  rescue
    error -> {:error, error}
  end

  # Tells one token from another without keeping it
  defp stamp(token), do: :sha256 |> :crypto.hash(token) |> Base.encode16(case: :lower)

  # Tells one auth section from another: a change makes every session work its role out again
  defp config_stamp do
    {Config.team_domain(), Config.audience(), Config.allowlist()}
    |> :erlang.phash2()
    |> Integer.to_string()
  end

  defp http, do: Application.get_env(:deployex_web, :cloudflare_access_http, Http)

  defp present?(value), do: is_binary(value) and value != ""
end
