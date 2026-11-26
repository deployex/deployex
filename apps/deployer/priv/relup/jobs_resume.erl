%% The instruction DeployEx puts at the end of a relup, see Deployer.HotUpgrade.Jobs.
%%
%% It resumes the Oban queues that jobs_pause.erl paused, and leaves what happened in
%% persistent_term, with the version in To, for DeployEx to read once the release is
%% installed.
%%
%% It runs after the point of no return, so nothing here may raise.
Key = {deployex, jobs},
try
    Paused =
        case persistent_term:get(Key, []) of
            List when is_list(List) -> List;
            _ -> []
        end,
    Resumed =
        [begin
             Outcome =
                 try
                     [ok = 'Elixir.Oban':resume_queue(Name, [{queue, Q}, {local_only, true}])
                      || Q <- Queues],
                     resumed
                 catch
                     _:_ -> failed
                 end,
             {Name, Queues, Jobs, Outcome}
         end || {Name, Queues, Jobs} <- Paused],
    persistent_term:put(Key, {To, Resumed})
catch
    _:_ -> ok
end,
ok.
