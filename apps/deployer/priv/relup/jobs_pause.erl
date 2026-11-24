%% The instruction DeployEx puts right after the point of no return of a relup, see
%% Deployer.HotUpgrade.Jobs.
%%
%% It pauses the Oban queues of this node, so no job starts while the code is replaced, and
%% waits for the jobs that are running as Oban does when it shuts down: for the
%% shutdown_grace_period of the instance, 20 seconds at most. A job that is still running
%% after that is left running, and is killed by the upgrade only if its code is replaced.
%%
%% A queue that was already paused is not touched, so it is not resumed either. What is to
%% be paused is left in persistent_term before any queue is paused, for the instruction at
%% the end of the relup to resume whatever happens here. These are expressions and not a
%% module, evaluated by erl_eval.
%%
%% It runs after the point of no return, where an instruction that fails restarts the node,
%% so nothing here may raise.
Key = {deployex, jobs},
try
    persistent_term:put(Key, []),
    Instances =
        case code:ensure_loaded('Elixir.Oban') of
            {module, _} ->
                Usable = erlang:function_exported('Elixir.Oban', pause_queue, 2) andalso
                         erlang:function_exported('Elixir.Oban', check_all_queues, 1) andalso
                         whereis('Elixir.Oban.Registry') =/= undefined,
                case Usable of
                    true ->
                        All = 'Elixir.Registry':select('Elixir.Oban.Registry',
                                                       [{{'$1', '_', '$2'}, [], [{{'$1', '$2'}}]}]),
                        [{Name, maps:get(shutdown_grace_period, Config, 15000)}
                         || {Name, Config} <- All, is_map(Config),
                            maps:get('__struct__', Config, undefined) =:= 'Elixir.Oban.Config'];
                    false -> []
                end;
            _ -> []
        end,
    Queues = fun(Name) -> [Q || Q <- 'Elixir.Oban':check_all_queues(Name), is_map(Q)] end,
    %% An instance with no queue to pause is left out
    Paused =
        lists:flatmap(
          fun({Name, Grace}) ->
              try
                  case [maps:get(queue, Q) || Q <- Queues(Name),
                                              maps:get(paused, Q, false) =:= false] of
                      [] -> [];
                      Running -> [{Name, Running, Grace}]
                  end
              catch
                  _:_ -> []
              end
          end, Instances),
    persistent_term:put(Key, [{Name, Qs, pending} || {Name, Qs, _Grace} <- Paused]),
    %% One at a time: a queue that fails to pause does not keep the others from being
    %% paused, nor any of them from being resumed. Resuming one that did not pause is
    %% harmless, it was running before.
    [try 'Elixir.Oban':pause_queue(Name, [{queue, Q}, {local_only, true}])
     catch _:_ -> failed
     end || {Name, Qs, _Grace} <- Paused, Q <- Qs],
    %% Jobs still running in the queues that were paused, or a queue that has not paused
    %% yet. A check that fails says nothing about the jobs, so it does not end the wait.
    Busy = fun(Name, Qs) ->
               try
                   lists:sum([case maps:get(paused, Q, false) of
                                  true -> length(maps:get(running, Q, []));
                                  false -> length(maps:get(running, Q, [])) + 1
                              end || Q <- Queues(Name), lists:member(maps:get(queue, Q), Qs)])
               catch
                   _:_ -> unknown
               end
           end,
    Wait = lists:min([20000 | [lists:max([Grace || {_, _, Grace} <- Paused]) || Paused =/= []]]),
    Deadline = erlang:monotonic_time(millisecond) + Wait,
    Loop = fun Loop() ->
               Left = [{Name, Qs, Busy(Name, Qs)} || {Name, Qs, _Grace} <- Paused],
               Done = lists:all(fun({_, _, N}) -> N =:= 0 end, Left),
               case Done orelse erlang:monotonic_time(millisecond) >= Deadline of
                   true -> Left;
                   false -> timer:sleep(100), Loop()
               end
           end,
    persistent_term:put(Key, [{Name, Qs, case N of
                                             0 -> finished;
                                             unknown -> unknown;
                                             _ -> {running, N}
                                         end}
                              || {Name, Qs, N} <- Loop()])
catch
    _:_ -> ok
end,
ok.
