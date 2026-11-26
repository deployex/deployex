defmodule DeployexWeb.OAuth.AllowlistTest do
  use ExUnit.Case, async: true

  alias DeployexWeb.OAuth.Allowlist

  test "empty or nil allowlist denies everyone (fail closed)" do
    assert Allowlist.check("me@co.com", %{emails: [], domains: []}) == :denied
    assert Allowlist.check("me@co.com", %{}) == :denied
    assert Allowlist.check("me@co.com", nil) == :denied
  end

  test "exact email match is allowed" do
    assert Allowlist.check("me@co.com", %{emails: ["me@co.com"], domains: []}) == :ok
  end

  test "domain match is allowed" do
    assert Allowlist.check("anyone@co.com", %{emails: [], domains: ["co.com"]}) == :ok
  end

  test "no match is denied" do
    assert Allowlist.check("stranger@evil.com", %{emails: ["me@co.com"], domains: ["co.com"]}) ==
             :denied
  end

  test "matching is case-insensitive" do
    assert Allowlist.check("me@co.COM", %{emails: ["Me@Co.com"], domains: []}) == :ok
  end

  describe "role/2" do
    @config %{
      emails: ["admin@co.com"],
      domains: ["ops.co.com"],
      read_only_emails: ["viewer@partner.com", "admin@co.com"],
      read_only_domains: ["co.com"]
    }

    test "an email or a domain on the admin lists is an admin" do
      assert Allowlist.role("admin@co.com", @config) == :admin
      assert Allowlist.role("Someone@OPS.co.com", @config) == :admin
    end

    test "an email or a domain on the read-only lists has read-only access" do
      assert Allowlist.role("viewer@partner.com", @config) == :read_only
      assert Allowlist.role("anyone@co.com", @config) == :read_only
      assert Allowlist.check("anyone@co.com", @config) == :ok
    end

    test "anyone else is denied" do
      assert Allowlist.role("other@partner.com", @config) == :denied
      assert Allowlist.role("admin@co.com", nil) == :denied
      assert Allowlist.role("admin@co.com", %{}) == :denied
      assert Allowlist.check("other@partner.com", @config) == :denied
    end
  end
end
