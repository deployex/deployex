%% The instruction DeployEx puts at the end of a relup, see Deployer.HotUpgrade.VersionUpdate.
%%
%% It moves the version the node reports on traces and logs to the one being installed.
%% These are expressions and not a module: the relup carries them as abstract forms, which
%% erl_eval evaluates with From and To bound to the two versions, as binaries.
%%
%% What it did is left in persistent_term, with the version it moved to, for DeployEx to read
%% once the release is installed. It is a few words, so it is not erased: the next upgrade
%% replaces it.
%%
%% It runs after the point of no return, where an instruction that fails restarts the node,
%% so nothing here may raise.
Swap = fun Swap(T, Old, New) when T =:= Old -> New;
           Swap(T, Old, New) when is_tuple(T) ->
               list_to_tuple([Swap(E, Old, New) || E <- tuple_to_list(T)]);
           Swap(T, Old, New) when is_list(T) ->
               try [Swap(E, Old, New) || E <- T] catch _:_ -> T end;
           Swap(T, Old, New) when is_map(T) ->
               maps:map(fun(_K, V) -> Swap(V, Old, New) end, T);
           Swap(T, _Old, _New) -> T
       end,
Traces =
    try
        case whereis(otel_resource_detector) of
            undefined -> no_sdk;
            _ ->
                OldRes = otel_resource_detector:get_resource(),
                Attributes = otel_attributes:map(otel_resource:attributes(OldRes)),
                case maps:get('service.version', Attributes, undefined) of
                    From ->
                        NewRes = otel_resource:merge(
                                   otel_resource:create(#{'service.version' => To}), OldRes),
                        Replace =
                            fun(Name) ->
                                case whereis(Name) of
                                    undefined -> ok;
                                    P ->
                                        try
                                            sys:replace_state(
                                              P, fun(S) -> Swap(S, OldRes, NewRes) end, 2000),
                                            ok
                                        catch _:_ -> failed
                                        end
                                end
                            end,
                        %% The detector is what says which version the node reports, so it
                        %% is replaced last, and only when the processes that export were:
                        %% an upgrade that could not reach one of them does not leave the
                        %% detector saying a version the node does not export
                        Exporting = [otel_tracer_provider_global, otel_batch_processor_global,
                                     otel_simple_processor_global],
                        case [N || N <- Exporting, Replace(N) =/= ok] of
                            [] ->
                                case Replace(otel_resource_detector) of
                                    ok -> updated;
                                    failed -> failed
                                end;
                            _NotReplaced -> failed
                        end;
                    Other -> {left_alone, Other}
                end
        end
    catch _:_ -> failed
    end,
Change = fun(Current, Set) ->
             case Swap(Current, From, To) of
                 Current -> 0;
                 Changed -> ok = Set(Changed), 1
             end
         end,
Logs =
    try
        Primary = logger:get_primary_config(),
        lists:sum(
          [Change(maps:get(K, Primary), fun(V) -> logger:set_primary_config(K, V) end)
           || K <- [filters, metadata], maps:is_key(K, Primary)] ++
          [Change(maps:get(K, H), fun(V) -> logger:set_handler_config(Id, K, V) end)
           || #{id := Id} = H <- logger:get_handler_config(),
              K <- [filters, formatter], maps:is_key(K, H)])
    catch _:_ -> failed
    end,
try persistent_term:put({deployex, version_update}, {To, Traces, Logs}) catch _:_ -> ok end,
{Traces, Logs}.
