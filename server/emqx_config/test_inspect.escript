main(_) ->
    {ok, {_, [{abstract_code, {_, Forms}}]}} = beam_lib:chunks(code:which(emqx_authn_mnesia), [abstract_code]),
    [io:format("~s~n", [erl_pp:function(F)]) || F <- Forms, element(1, F) =:= function, element(3, F) =:= import_users].

