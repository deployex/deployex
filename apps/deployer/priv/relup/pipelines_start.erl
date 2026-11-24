%% The instruction DeployEx puts at the end of a relup, see Deployer.HotUpgrade.Pipelines.
%%
%% It starts the Broadway pipelines that pipelines_stop.erl stopped, now on the new code,
%% and leaves what happened to each one in persistent_term, with the version in To, for
%% DeployEx to read once the release is installed.
%%
%% It runs after the point of no return, so nothing here may raise.
Key = {deployex, pipelines},
try
    Stopped =
        case persistent_term:get(Key, []) of
            List when is_list(List) -> List;
            _ -> []
        end,
    Started =
        [begin
             Outcome =
                 try supervisor:restart_child(Parent, Id) of
                     {ok, _} -> started;
                     {ok, _, _} -> started;
                     %% It never stopped, or its supervisor started it again
                     {error, running} -> started;
                     {error, _} -> failed
                 catch
                     _:_ -> failed
                 end,
             {Name, Stop, Outcome}
         end || {Name, Parent, Id, Stop} <- Stopped],
    persistent_term:put(Key, {To, Started})
catch
    _:_ -> ok
end,
ok.
