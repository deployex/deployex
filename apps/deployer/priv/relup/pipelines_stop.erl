%% The instruction DeployEx puts right after the point of no return of a relup, see
%% Deployer.HotUpgrade.Pipelines.
%%
%% It stops the Broadway pipelines of the node before any module is replaced. A pipeline
%% that is stopped through its supervisor lets the messages it is handling finish, so none
%% of them is inside code that the upgrade is about to purge.
%%
%% What it stopped is left in persistent_term before anything is stopped, so the
%% instruction at the end of the relup starts the same pipelines again whatever happens
%% here. These are expressions and not a module, evaluated by erl_eval.
%%
%% It runs after the point of no return, where an instruction that fails restarts the node,
%% so nothing here may raise.
Key = {deployex, pipelines},
try
    persistent_term:put(Key, []),
    Names =
        case code:ensure_loaded('Elixir.Broadway') of
            {module, _} ->
                case erlang:function_exported('Elixir.Broadway', all_running, 0) of
                    true -> 'Elixir.Broadway':all_running();
                    false -> []
                end;
            _ -> []
        end,
    %% A pipeline is a child of the supervisor that started it. One that was not started
    %% under a name, or by a supervisor that keeps no child to start again, is left alone.
    Find = fun(Name) ->
               Pid = whereis(Name),
               {dictionary, Dictionary} = process_info(Pid, dictionary),
               [Parent | _] = proplists:get_value('$ancestors', Dictionary),
               [Id] = [I || {I, P, _, _} <- supervisor:which_children(Parent),
                            P =:= Pid, I =/= undefined],
               {Name, Parent, Id}
           end,
    Found = lists:flatmap(fun(Name) -> try [Find(Name)] catch _:_ -> [] end end, Names),
    persistent_term:put(Key, [{N, P, I, pending} || {N, P, I} <- Found]),
    %% All at once, each one waits for its own messages. 30 seconds for all of them, which is
    %% as long as a pipeline gives its own messages unless it was told otherwise: the
    %% release handler is waiting, and so is whoever asked for the upgrade.
    Stops = [{N, P, I, spawn_monitor(fun() -> exit({stopped, supervisor:terminate_child(P, I)}) end)}
             || {N, P, I} <- Found],
    Deadline = erlang:monotonic_time(millisecond) + 30000,
    Stopped =
        [begin
             Left = max(Deadline - erlang:monotonic_time(millisecond), 0),
             Outcome =
                 receive
                     {'DOWN', Ref, process, _, {stopped, ok}} -> stopped;
                     {'DOWN', Ref, process, _, _Other} -> failed
                 after Left ->
                     erlang:demonitor(Ref, [flush]),
                     timeout
                 end,
             {N, P, I, Outcome}
         end || {N, P, I, {_Pid, Ref}} <- Stops],
    persistent_term:put(Key, Stopped)
catch
    _:_ -> ok
end,
ok.
