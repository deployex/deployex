%% The instruction DeployEx puts at the end of a relup, see Deployer.HotUpgrade.Protocols.
%%
%% An Elixir release consolidates its protocols: each protocol is compiled again with the
%% list of its implementations, and those modules are kept in releases/<version>/consolidated,
%% outside of every application. No appup covers them, so a hot upgrade loads the new
%% implementations and leaves the protocols as they were when the node booted, not knowing
%% them: the first value of a struct the release added raises Protocol.UndefinedError.
%%
%% This loads every consolidated protocol of the release in To, under the release directory
%% in Root, whose code is not the one that is loaded, and moves the code path to its
%% directory. What it did is left in
%% persistent_term, with the version, for DeployEx to read once the release is installed.
%% These are expressions and not a module, evaluated by erl_eval.
%%
%% It runs after the point of no return, where an instruction that fails restarts the node,
%% so nothing here may raise.
Key = {deployex, protocols},
try
    Dir = filename:join([binary_to_list(Root), "releases", binary_to_list(To), "consolidated"]),
    Result =
        case filelib:is_dir(Dir) of
            false ->
                none;
            true ->
                Reload =
                    fun(Beam) ->
                        Module = list_to_atom(filename:rootname(Beam)),
                        File = filename:join(Dir, Beam),
                        try
                            {ok, {Module, OnDisk}} = beam_lib:md5(File),
                            Current = code:is_loaded(Module) =/= false andalso
                                      Module:module_info(md5) =:= OnDisk,
                            case Current of
                                true ->
                                    [];
                                false ->
                                    %% Only a process still inside the version before the
                                    %% loaded one is in the way, and has to go
                                    case code:soft_purge(Module) of
                                        true -> ok;
                                        false -> code:purge(Module)
                                    end,
                                    {module, Module} = code:load_abs(filename:rootname(File)),
                                    [{Module, reloaded}]
                            end
                        catch
                            _:_ -> [{Module, failed}]
                        end
                    end,
                Reloaded = lists:flatmap(Reload, lists:sort(filelib:wildcard("*.beam", Dir))),
                %% For what is loaded by name later, such as after a module is purged
                [code:del_path(Path) || Path <- code:get_path(),
                                        filename:basename(Path) =:= "consolidated"],
                code:add_patha(Dir),
                Reloaded
        end,
    persistent_term:put(Key, {To, Result})
catch
    _:_ -> ok
end,
ok.
