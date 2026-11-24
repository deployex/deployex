%% The instruction DeployEx puts at the end of a relup, see Deployer.HotUpgrade.Pipelines.
%%
%% It starts the Broadway pipelines that pipelines_stop.erl stopped, now on the new code,
%% and leaves what happened to each one in persistent_term, with the version in To, for
%% DeployEx to read once the release is installed.
%%
%% The supervisor of a pipeline that is still stopping does not answer until it has
%% stopped, so each one is started from a process of its own, 10 seconds for all of them.
%% One that takes longer is no longer waited for, and starts when its supervisor gets to it.
%%
%% It runs after the point of no return, so nothing here may raise.
Key = {deployex, pipelines},
try
    Stopped =
        case persistent_term:get(Key, []) of
            List when is_list(List) -> List;
            _ -> []
        end,
    Starts =
        [{Name, Stop,
          spawn_monitor(
            fun() ->
                exit({start,
                      try supervisor:restart_child(Parent, Id) of
                          {ok, _} -> started;
                          {ok, _, _} -> started;
                          %% It never stopped, or its supervisor started it again
                          {error, running} -> started;
                          {error, _} -> failed
                      catch
                          _:_ -> failed
                      end})
            end)} || {Name, Parent, Id, Stop} <- Stopped],
    Deadline = erlang:monotonic_time(millisecond) + 10000,
    Started =
        [begin
             Left = max(Deadline - erlang:monotonic_time(millisecond), 0),
             Outcome =
                 receive
                     {'DOWN', Ref, process, _, {start, started}} -> started;
                     %% Its supervisor may have been started again by the upgrade, and the
                     %% pipeline with it
                     {'DOWN', Ref, process, _, _Other} ->
                         case catch whereis(Name) of
                             Pid when is_pid(Pid) -> started;
                             _ -> failed
                         end
                 after Left ->
                     erlang:demonitor(Ref, [flush]),
                     timeout
                 end,
             {Name, Stop, Outcome}
         end || {Name, Stop, {_Pid, Ref}} <- Starts],
    persistent_term:put(Key, {To, Started})
catch
    _:_ -> ok
end,
ok.
