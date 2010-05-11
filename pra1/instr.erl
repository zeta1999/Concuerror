-module(instr).
-export([instrument_and_load/1]).

-spec instrument_and_load(string()) -> 'ok' | 'error'.

%% Instrument and load a file.
instrument_and_load(File) ->
    %% A table for holding used variable names.
    ets:new(used, [named_table, private]),
    %% Instrument given source file.
    log:log("Instrumenting file `~s`... ", [File]),
    case instrument(File) of
	{ok, NewForms} ->
	    log:log("ok~n"),
	    %% Delete `used` table.
	    ets:delete(used),
	    %% Compile instrumented code.
	    CompOptions = [binary, verbose, report_errors, report_warnings],
	    case compile:forms(NewForms, CompOptions) of
		{ok, Module, Binary} ->
		    log:log("Loading module `~p`... ", [Module]),
		    case code:load_binary(Module, File, Binary) of
			{module, Module} ->
			    log:log("ok~n"),
			    ok;
			{error, Error} ->
			    log:log("error~n~p~n", [Error]),
			    error
		    end;
		error ->
		    error
	    end;
	{error, Error} ->
	    log:log("error~n~p~n", [Error]),
	    %% Delete `used` table.
	    ets:delete(used),
	    error
    end.

instrument(File) ->
    %% TODO: For now using an empty include path. In the future we have to
    %%       provide a means for an externally defined include path (like the
    %%       erlc -I flag).
    case epp:parse_file(File, [], []) of
	{ok, OldForms} ->
	    Tree = erl_recomment:recomment_forms(OldForms, []),
	    MapFun = fun(T) -> instrument_toplevel(T) end,
	    Transformed = erl_syntax_lib:map_subtrees(MapFun, Tree),
	    Abstract = erl_syntax:revert(Transformed),
	    %% io:put_chars(erl_prettypr:format(Abstract)),
	    NewForms = erl_syntax:form_list_elements(Abstract),
	    {ok, NewForms};
	{error, Error} -> {error, Error}
    end.

%% Instrument a "top-level" element.
%% Of the "top-level" elements, i.e. functions, specs, etc., only functions are
%% transformed, so leave everything else as is.
instrument_toplevel(Tree) ->
    case erl_syntax:type(Tree) of
	function -> instrument_function(Tree);
	_Other -> Tree
    end.

%% Instrument a function.
instrument_function(Tree) ->
    %% Delete previous entry in `used` table (if any).
    ets:delete_all_objects(used),
    %% A set of all variables used in the function.
    Used = erl_syntax_lib:variables(Tree),
    %% Insert the used set into `used` table.
    ets:insert(used, {used, Used}),
    instrument_subtrees(Tree).

%% Instrument all subtrees of Tree.
instrument_subtrees(Tree) ->
    MapFun = fun(T) -> instrument_term(T) end,
    erl_syntax_lib:map_subtrees(MapFun, Tree).

%% Instrument a term.
instrument_term(Tree) ->
    case erl_syntax:type(Tree) of
	application ->
	    Qualifier = erl_syntax:application_operator(Tree),
	    case erl_syntax:type(Qualifier) of
		atom ->
		    Function = erl_syntax:atom_value(Qualifier),
		    case Function of
			spawn ->
			    instrument_spawn(instrument_subtrees(Tree));
			_Other -> Tree
		    end;
		_Other -> Tree
	    end;
	infix_expr ->
	    Operator = erl_syntax:infix_expr_operator(Tree),
	    case erl_syntax:operator_name(Operator) of
		'!' -> instrument_send(instrument_subtrees(Tree));
		_Other -> Tree
	    end;
	receive_expr ->
	    instrument_receive(instrument_subtrees(Tree));
	%% Replace every underscore with a new (underscore-prefixed) variable.
	underscore ->
	    [{used, Used}] = ets:lookup(used, used),
	    Fresh = erl_syntax_lib:new_variable_name(Used),
	    String = "_" ++ atom_to_list(Fresh),
	    erl_syntax:variable(String);
	_Other -> instrument_subtrees(Tree)
    end.

%% Instrument a receive expression.
instrument_receive(Tree) ->
    Module = erl_syntax:atom(sched),
    Function = erl_syntax:atom(rep_receive),
    %% Get old receive expression's clauses.
    OldClauses = erl_syntax:receive_expr_clauses(Tree),
    NewClauses = lists:map(fun(Clause) -> transform_receive_clause(Clause) end,
			   OldClauses),
    %% `receive ... after` not supported for now.
    case erl_syntax:receive_expr_timeout(Tree) of
	none -> continue;
	_Any -> log:internal("`receive ... after` expressions not supported.~n")
    end,
    %% Create new receive expression adding the `after 0` part.
    Timeout = erl_syntax:integer(0),
    %% Create new variable to use as 'Aux'.
    [{used, Used}] = ets:lookup(used, used),
    Fresh = erl_syntax_lib:new_variable_name(Used),
    FunVar = erl_syntax:variable(Fresh),
    Action = erl_syntax:application(FunVar, []),
    NewRecv = erl_syntax:receive_expr(NewClauses, Timeout, [Action]),
    %% Create a new fun to be the argument of rep_receive.
    FunClause = erl_syntax:clause([FunVar], [], [NewRecv]),
    FunExpr = erl_syntax:fun_expr([FunClause]),
    %% Call sched:rep_receive.
    erl_syntax:application(Module, Function, [FunExpr]).

%% Tranforms a clause
%%   Msg -> [Actions]
%% to
%%   {SenderPid, Msg} -> {SenderPid, Msg, [Actions]}
%%
%% (temporarily Msg -> {Msg, [Actions]})
transform_receive_clause(Clause) ->
    [OldPattern] = erl_syntax:clause_patterns(Clause),
    OldGuard = erl_syntax:clause_guard(Clause),
    OldBody = erl_syntax:clause_body(Clause),
    %% Create new variable to use as 'SenderPid'.
    [{used, Used}] = ets:lookup(used, used),
    Fresh = erl_syntax_lib:new_variable_name(Used),
    PidVar = erl_syntax:variable(Fresh),
    NewPattern = [erl_syntax:tuple([PidVar,
				     OldPattern])],
    Module = erl_syntax:atom(sched),
    Function = erl_syntax:atom(rep_receive_notify),
    Arguments = [PidVar, OldPattern],
    Notify = erl_syntax:application(Module, Function, Arguments),
    NewBody = [Notify | OldBody],
    erl_syntax:clause(NewPattern, OldGuard, NewBody).

%% Instrument a Pid ! Msg expression.
%% Pid ! Msg is transformed into rep:send(Pid, Msg).
instrument_send(Tree) ->
    Module = erl_syntax:atom(sched),
    Function = erl_syntax:atom(rep_send),
    Pid = erl_syntax:infix_expr_left(Tree),
    Msg = erl_syntax:infix_expr_right(Tree),
    Sender = erl_syntax:application(erl_syntax:atom(self), []),
    Arguments = [Pid, erl_syntax:tuple([Sender, Msg])],
    erl_syntax:application(Module, Function, Arguments).

%% Instrument a spawn expression (only in the form spawn(fun() -> Body end
%% for now).
%% spawn(Fun) is transformed into sched:rep_spawn(Fun).
instrument_spawn(Tree) ->
    Module = erl_syntax:atom(sched),
    Function = erl_syntax:atom(rep_spawn),
    %% Fun expression arguments of the (before instrumentation) spawn call.
    Arguments = erl_syntax:application_arguments(Tree),
    erl_syntax:application(Module, Function, Arguments).
