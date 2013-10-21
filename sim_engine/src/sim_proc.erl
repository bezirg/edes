-module(sim_proc).

%% API exports
%% 
-export([start/3, start/4,
         start_link/3, start_link/4,
         format_status/2,
         schedule/2, schedule/3, 
         clock/0,                               % like SimPy's now()
         print/1, print/2, 
         println/1, println/2,
         link_from/1, link_to/2
         %% add_link/1, remove_link/1, unschedule/1
        ]).


%% System exports
%% 
-export([
         init_it/6,
         system_continue/3,
         system_terminate/4,
         system_code_change/4
         ]).


%%  Types and Callbacks
%% 
-callback init(Args :: term()) ->
    {ok, State :: term()} | {ok, State :: term(), timeout()} |
    {stop, Reason :: term()} | ignore.
-callback handle_event(Event :: term(), State :: term()) ->
    {ok, NewState :: term()} |
    {stop, Reason :: term(), NewState :: term()}.
-callback handle_info(Info :: timeout() | term(), State :: term()) ->
    {noreply, NewState :: term()} |
    {noreply, NewState :: term(), timeout() | hibernate} |
    {stop, Reason :: term(), NewState :: term()}.
-callback terminate(Reason :: (normal | shutdown | {shutdown, term()} |
                               term()),
                    State :: term()) ->
    term().
-callback code_change(OldVsn :: (term() | {down, term()}), State :: term(),
                      Extra :: term()) ->
    {ok, NewState :: term()} | {error, Reason :: term()}.


%% API
%% 
%% @doc Callback, not documented
start(Mod, Args, Options) ->
    gen:start(?MODULE, nolink, Mod, Args, Options).

%% @doc Callback, not documented
start(Name, Mod, Args, Options) ->
    gen:start(?MODULE, nolink, Name, Mod, Args, Options).

%% @doc Callback, not documented
start_link(Mod, Args, Options) ->
    gen:start(?MODULE, link, Mod, Args, Options).

%% @doc Callback, not documented
start_link(Name, Mod, Args, Options) ->
    gen:start(?MODULE, link, Name, Mod, Args, Options).

%% @doc Callback, not documented
format_status(Opt, StatusData) ->
    [PDict, SysState, Parent, Debug, [Name, State, Mod, _Time]] = StatusData,
    Header = gen:format_status_header("Status for simulation process",
                                      Name),
    Log = sys:get_debug(log, Debug, []),
    DefaultStatus = [{data, [{"State", State}]}],
    Specfic =
	case erlang:function_exported(Mod, format_status, 2) of
	    true ->
		case catch Mod:format_status(Opt, [PDict, State]) of
		    {'EXIT', _} -> DefaultStatus;
                    StatusList when is_list(StatusList) -> StatusList;
		    Else -> [Else]
		end;
	    _ ->
		DefaultStatus
	end,
    [{header, Header},
     {data, [{"Status", SysState},
	     {"Parent", Parent},
	     {"Logged events", Log}]} |
     Specfic].

%% API

%% @doc API, schedules a local Event on Time
-spec schedule(Event :: term(), Time :: number()) -> ok.
schedule(Event, Time) ->
    ScheduledTime = Time + get(clock),
    Event_list = get(local),
    put(local, [{ScheduledTime, Event} | Event_list]),
    case get(debug) of
        [] -> ok;
        Debug -> sys:handle_debug(Debug, fun print_event/3, get(name), {schedule, Event, ScheduledTime})
    end,
    ok.            

%% @doc API, schedules a remote Event in LP on Time
-spec schedule(LP :: atom(), Event :: term(), Time :: number()) -> ok.
schedule(LP, Event, Time) ->
    ScheduledTime = Time + get(clock),
    Lookahead = get(lookahead),
    case lists:keyfind(LP, 1, Lookahead) of
        {LP, LP_Lookahead, LastMessage} -> case ScheduledTime < LastMessage of
                                            true -> error(message_out_of_sequence);
                                            false -> % send the event to schedule
                                                   LP ! {schedule, get(name), Event, ScheduledTime}, 
                                                   case ScheduledTime > LastMessage of
                                                       true ->
                                                           %% update the last message 
                                                           put(lookahead, lists:keyreplace(LP, 1, Lookahead, {LP, LP_Lookahead, ScheduledTime}));
                                                       false -> ok
                                                   end
                                           end;
        false -> error(link_not_created)
    end,
    case get(debug) of
        [] -> ok;
        Debug -> sys:handle_debug(Debug, fun print_event/3, LP, {schedule, Event, ScheduledTime})
    end,
    ok.

%% unschedule(Event) ->
%%     Event_list = get(local),
%%     put(local, lists:keydelete(Event, 2, Event_list)),
%%     case get(debug) of
%%         [] -> ok;
%%         Debug -> sys:handle_debug(Debug, fun print_event/3, get(name), {unschedule, Event})
%%     end,
%%     ok.

%% @doc API, prints Str
-spec print(Str :: string()) -> ok.
print(Str) ->
    print(Str, []).

%% @doc API, prints Str with Args
-spec print(Str :: string(), Args :: [term()]) -> ok.
print(Str, Args) ->
    io:format("~p/~p: " ++ Str, [get(name),get(clock) | Args]).

%% @doc API, prints Str followed by newline
-spec println(Str :: string()) -> ok.
println(Str) ->
    print(Str ++ "~n", []).

%% @doc API, prints Str with Args followed by newline
-spec println(Str :: string(), Args :: [term()]) -> ok.
println(Str, Args) ->
    print(Str ++ "~n", Args).

%% @doc API, returns the current simulation time of the calling LP.
%% Same as the now() function of SimPy
-spec clock() -> number().
clock() ->
    get(clock).

%% @doc API, creates a link from the remote LP to the caller LP
-spec link_from(LP :: atom()) -> ok.
link_from(LP) ->
    %% add the queue ref
    put(remotes, sets:add_element(LP, get(remotes))),
    %% initialize the queue
    put(LP, queue:new()),
    ok.

%% @doc API, creates a link to the remote LP from the caller LP with the specified lookahead
-spec link_to(LP :: atom(), LookaheadVal :: number()) -> ok.
link_to(LP, LookaheadVal) ->
    Lookahead = get(lookahead),
    % stores a triple {LogicalProcess, LookaheadValue, LastMessageTime} in the association list get(lookahead)
    Lookahead_ = lists:keystore(LP, 1, Lookahead, {LP, LookaheadVal, -1}), 
    put(lookahead, Lookahead_),
    ok.


%% @doc Internal, removes link to the remote LP
-spec remove_link(LP :: atom()) -> ok.
remove_link(LP) ->
    %% remove the lookahead
    Lookahead = get(lookahead),
    Lookahead_ = lists:keydelete(LP, 1, Lookahead),
    put(lookahead, Lookahead_),

    %% inform the LP, so the LP can move the queue events to the local queue
    try LP ! {remove_link, get(name)} of
        _ -> ok
    catch
        error:badarg -> ok                       % LP is down, so don't have to remove link
    end.


%% @doc Internal, removes links of the caller LP
-spec remove_links() -> ok.
remove_links() ->
    %% removes the links of this LP
    Lookahead = get(lookahead),
    lists:foreach(fun ({LP,_,_}) -> remove_link(LP) end, Lookahead). % can be optimized by code inlining
                         



%% System functions
%% 

%% @doc Callback, not documented
init_it(Starter, self, Name, Mod, Args, Options) ->
    init_it(Starter, self(), Name, Mod, Args, Options);
init_it(Starter, Parent, Name0, Mod, Args, Options) ->
    Name = name(Name0),
    Debug = debug_options(Name, Options),
    put(debug, Debug),                          % debug options
    put(name, Name),                            % name declared at sim_controller
    put(clock, 0),                              % clock initialized to 0
    put(remotes, sets:new()),                   % a set of remote event queues
    put(local,[]),                              % the local event list/queue :: [{ScheduledTime :: number(), Event :: term()}]
    put(lookahead, []),                         % the lookaheads of outgoing LPs :: [{LPName :: atom(), LookaheadValue :: number(), LastMessageTime :: number()}]
    case catch Mod:init(Args) of
	{ok, State} ->
	    proc_lib:init_ack(Starter, {ok, self()}),
        sync_controller(),
	    loop(Parent, Name, State, Mod, infinity, Debug);
	{ok, State, Timeout} ->
	    proc_lib:init_ack(Starter, {ok, self()}), 	    
        %put(timeout, Timeout),                  % init the timeout for null-message optimization in send_nulls
        sync_controller(),
	    loop(Parent, Name, State, Mod, Timeout, Debug);
	{stop, Reason} ->
	    unregister_name(Name0),
	    proc_lib:init_ack(Starter, {error, Reason}),
	    exit(Reason);
	ignore ->
	    unregister_name(Name0),
	    proc_lib:init_ack(Starter, ignore),
	    exit(normal);
	{'EXIT', Reason} ->
	    unregister_name(Name0),
	    proc_lib:init_ack(Starter, {error, Reason}),
	    exit(Reason);
	Else ->
	    Error = {bad_return_value, Else},
	    proc_lib:init_ack(Starter, {error, Error}),
	    exit(Error)
    end.

%% @doc Callback, not documented
system_continue(Parent, Debug, [Name, State, Mod, Time]) ->
    loop(Parent, Name, State, Mod, Time, Debug).

-spec system_terminate(_, _, _, [_]) -> no_return().
%% @doc Callback, not documented
system_terminate(Reason, _Parent, Debug, [Name, State, Mod, _Time]) ->
    terminate(Reason, Name, [], Mod, State, Debug).
%% @doc Callback, not documented
system_code_change([Name, State, Mod, Time], _Module, OldVsn, Extra) ->
    case catch Mod:code_change(OldVsn, State, Extra) of
	{ok, NewState} -> {ok, [Name, NewState, Mod, Time]};
	Else -> Else
    end.

%% Internal functions

%% @doc Internal, Main Logical Process loop
loop(Parent, Name, State, Mod, Timeout, Debug) ->
    wait_remotes(),
    {EventTime, Event} = remove_smallest_timestamp(),
    %% Unsorted_event_list = get(local),
    %% case Unsorted_event_list of
    %%     [] -> terminate(normal, Name, [], Mod, State, Debug);
    %%     _ -> ok
    %% end,
    Next_clock = EventTime,
    Clock = get(clock),
    case Next_clock < Clock of
        true -> error({engine_error, Next_clock, queue:to_list(get(hd(sets:to_list(get(remotes)))))});
        false ->
            case Next_clock > Timeout of        % timeout is reached
                true -> put(clock, Timeout),
                        terminate(timeout, Name, [], Mod, State, Debug);
                false -> put(clock, Next_clock),
                         send_nulls(Next_clock),
                         case Event == null of
                             true -> % is a null message
                                     loop(Parent, Name, State, Mod, Timeout, Debug);
                             false -> Res = Mod:handle_event(Event, State),
                                      case Debug =:= [] of
                                          true -> handle_res(Res, Next_clock, Parent, Name, State, Mod, Timeout);
                                          false -> handle_res(Res, Next_clock, Parent, Name, State, Mod, Timeout, Debug)
                                      end
                         end
            end
    end.

%% @doc Internal, synchronizes the caller LP with the simulation controller upon initialization
-spec sync_controller() -> ok.
sync_controller() ->
    receive
        {controller_sync, Controller} ->  send_nulls(0), % initiate lookahead
                                          Controller ! ok
    end.
            

%% @doc Internal, Remote LPs have to respond; If remote LPs finished, then moves their remote queue to local.
-spec wait_remotes() -> ok.
wait_remotes() ->
    case lists:any(fun (Q) -> queue:is_empty(get(Q)) end, sets:to_list(get(remotes))) of % can be optimized with a sets:fold
        true -> receive
                    {remove_link, From} -> put(remotes, sets:del_element(From, get(remotes))),
                                           %% move to local
                                           put(local, get(local) ++ queue:to_list(get(From))),
                                           erase(From);
                    {schedule, From, Event, Time} ->  put(From, queue:in({Time, Event}, get(From)))
                end,
                wait_remotes();
        false -> ok
    end.
        
%% @doc Internal, removes the event with the smallest timestamp from the local queue or the remote queues and returns it
-spec remove_smallest_timestamp() -> Event :: term().
remove_smallest_timestamp() ->
    % can be optimized with a sets:fold 
    SmallestQueue = lists:foldl(fun (Q,Acc) -> min({queue:get(get(Q)), Q}, Acc) end, {{infinity, undefined}, undefined}, sets:to_list(get(remotes))), 
    {RemoteEvent, Queue} = SmallestQueue,
    %% sort local
    {LocalEvent, Rest_local} = case lists:sort(get(local)) of
                                   [L | Ls] -> {L, Ls};
                                   [] -> {{infinity, undefined}, []} % local is empty
                               end,
    case RemoteEvent < LocalEvent of
        true -> put(Queue, queue:drop(get(Queue))),
                RemoteEvent;
        false -> put(local, Rest_local),
                 LocalEvent
    end.


%% @doc Internal, handles the result of the event dispatching
handle_res(Res, Clock, Parent, Name, State, Mod, Timeout) ->
    case Res of
        {ok, NState} ->
            loop(Parent, Name, NState, Mod, Timeout, []);
        {ok, NState, Time1} ->
            loop(Parent, Name, NState, Mod, Clock + Time1, []);
        {stop, Reason, NState} ->
            terminate(Reason, Name, Res, Mod, NState, []);
        _ ->
            terminate({bad_return_value, Res}, Name, Res, Mod, State, [])
    end.

%% @doc Internal, handles the result of the event dispatching
handle_res(Res, Clock, Parent, Name, State, Mod, Timeout, Debug) ->
    case Res of
	{ok, NState} ->
	    Debug1 = sys:handle_debug(Debug, fun print_event/3, Name,
				      {ok, NState}),
	    loop(Parent, Name, NState, Mod, Timeout, Debug1);
	{ok, NState, Time1} ->
	    Debug1 = sys:handle_debug(Debug, fun print_event/3, Name,
				      {ok, NState}),
	    loop(Parent, Name, NState, Mod, Clock + Time1, Debug1);
 	{stop, Reason, NState} ->
	    terminate(Reason, Name, Res, Mod, NState, Debug);
	_ ->
	    terminate({bad_return_value, Res}, Name, Res, Mod, State, Debug)
    end.


%% @doc Internal, schedules null messages to the LPs with their proper lookahead according to caller LP, on the next clock specified
-spec send_nulls(Clock :: number()) -> ok.
send_nulls(Clock) ->
    Lookahead_ = lists:map(fun (X = {undefined, _Lookahead, _LastMessage}) -> X; % don't process LPs that are down
                               ({LP, Lookahead, LastMessage}) -> 
                                   case Clock + Lookahead > LastMessage of % andalso Clock + Lookahead =< get(timeout) of
                                       true ->           % then send the null message and update the last message sent
                                           try LP ! {schedule, get(name), null, Clock + Lookahead} of
                                               _ -> case get(debug) of %% if debug enabled
                                                        [] -> ok;
                                                        Debug -> sys:handle_debug(Debug, fun print_event/3, get(name), {null, LP, Clock})
                                                    end,
                                                    {LP, Lookahead, Clock + Lookahead}
                                           catch
                                               error:badarg -> {undefined, Lookahead, LastMessage} % LP is down
                                           end;
                                       false -> {LP, Lookahead, LastMessage} % else don't send null message and don't update the last message
                                   end
                           end, get(lookahead)),
    put(lookahead, Lookahead_),                 % update the process dictionary
    ok.


%% @doc Internal, removes incoming links, calls Mod:terminate, exits the LP
terminate(Reason, Name, Msg, Mod, State, Debug) ->
    remove_links(),                             % Remove outgoing links
    case catch Mod:terminate(Reason, State) of
	{'EXIT', R} ->
	    error_info(R, Name, Msg, State, Debug),
	    exit(R);
	_ ->
	    case Reason of
            normal ->
                exit(normal);
            timeout ->
                exit(normal);                       % otp considers non-normal,shutdown as crashes
            shutdown ->
                exit(shutdown);
            {shutdown,_}=Shutdown ->
                exit(Shutdown);
		_ ->
		    FmtState =
			case erlang:function_exported(Mod, format_status, 2) of
			    true ->
				Args = [get(), State],
				case catch Mod:format_status(terminate, Args) of
				    {'EXIT', _} -> State;
				    Else -> Else
				end;
			    _ ->
				State
			end,
		    error_info(Reason, Name, Msg, FmtState, Debug),
		    exit(Reason)
	    end
    end.

%% @doc Internal, Debugging printing, called by terminate
error_info(_Reason, application_controller, _Msg, _State, _Debug) ->
    ok;
error_info(Reason, Name, Msg, State, Debug) ->
    Reason1 = 
	case Reason of
	    {undef,[{M,F,A,L}|MFAs]} ->
		case code:is_loaded(M) of
		    false ->
			{'module could not be loaded',[{M,F,A,L}|MFAs]};
		    _ ->
			case erlang:function_exported(M, F, length(A)) of
			    true ->
				Reason;
			    false ->
				{'function not exported',[{M,F,A,L}|MFAs]}
			end
		end;
	    _ ->
		Reason
	end,    
    error_logger:format("** Simulation process ~p terminating \n"
                        "** Last message in was ~p~n"
                        "** When Server state == ~p~n"
                        "** Reason for termination == ~n** ~p~n",
	   [Name, Msg, State, Reason1]),
    sys:print_log(Debug),
    ok.

%% @doc Internal, Debugging printing , debug flag must be enabled upon start ({debug, trace | log | ...})
print_event(Dev, {ok, State}, Name) ->
    io:format(Dev, "*DBG* ~p new state ~w~n", [Name, State]);
print_event(Dev, {schedule, Event, Time}, Name) ->
    io:format(Dev, "*DBG* ~p scheduled ~w on ~p ~n", [Name, Event, Time]);
print_event(Dev, {null, LP, Clock}, Name ) ->
    io:format(Dev, "*DBG* ~p/~p sent null to ~p ~n", [Name, Clock, LP]);
print_event(Dev, {unschedule, Event}, Name) ->
    io:format(Dev, "*DBG* ~p unscheduled ~w ~n", [Name, Event]);
print_event(Dev, Event, Name) ->
    io:format(Dev, "*DBG* ~p dbg  ~p~n", [Name, Event]).




%% Misc functions
%% 

%% @doc Misc, not documented
name({local,Name}) -> Name;
name({global,Name}) -> Name;
name({via,_, Name}) -> Name;
name(Pid) when is_pid(Pid) -> Pid.

%% @doc Misc, not documented
unregister_name({local,Name}) ->
    _ = (catch unregister(Name));
unregister_name({global,Name}) ->
    _ = global:unregister_name(Name);
unregister_name({via, Mod, Name}) ->
    _ = Mod:unregister_name(Name);
unregister_name(Pid) when is_pid(Pid) ->
    Pid.
    
%% @doc Misc, not documented
opt(Op, [{Op, Value}|_]) ->
    {ok, Value};
opt(Op, [_|Options]) ->
    opt(Op, Options);
opt(_, []) ->
    false.

%% @doc Misc, not documented
debug_options(Name, Opts) ->
    case opt(debug, Opts) of
	{ok, Options} -> dbg_options(Name, Options);
	_ -> dbg_options(Name, [])
    end.

%% @doc Misc, not documented
dbg_options(Name, []) ->
    Opts = 
	case init:get_argument(generic_debug) of
	    error ->
		[];
	    _ ->
		[log, statistics]
	end,
    dbg_opts(Name, Opts);
dbg_options(Name, Opts) ->
    dbg_opts(Name, Opts).

%% @doc Misc, not documented
dbg_opts(Name, Opts) ->
    case catch sys:debug_options(Opts) of
	{'EXIT',_} ->
	    error_logger:format("~p: ignoring erroneous debug options - ~p~n",
		   [Name, Opts]),
	    [];
	Dbg ->
	    Dbg
    end.
