%% The instruction DeployEx puts at the head of a relup, see install_runtime_config_hook/2 in
%% Deployer.HotUpgrade.Application.
%%
%% These are expressions and not a module: the relup carries them as abstract forms, which
%% erl_eval evaluates. The configuration itself cannot travel in the relup, so DeployEx puts
%% it in persistent_term before the release is installed.
%%
%% The stash is erased as the last act. It holds whatever the Config Providers produced,
%% secrets included, so it must not outlive the upgrade that needed it.
application:set_env(persistent_term:get({deployex, runtime_config}), [{persistent, true}]),
persistent_term:erase({deployex, runtime_config}).
