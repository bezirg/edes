-module(lax).
-behaviour(sim_proc).
-compile(export_all).


%% constants
-define(R, 10). % time runway in use to land aircraft
-define(G, 5). % time required at gate

%% state variables
-record(state, {in_the_air,
                on_the_ground,
                runway_free}).

init(_Args) ->
    %% initialize state_variables
    State = #state{in_the_air = 0, 
                   on_the_ground = 0, 
                   runway_free = true},

    %% schedule initial event
    sim_proc:schedule(arrival, 30),
    sim_proc:schedule(arrival, 10),

    %% incoming links
    sim_proc:link_from(abd),

    %% outgoing links with lookahead
    sim_proc:link_to(ord, 3),

    {ok, State, 40}.
    %%{ok, State, MaxTime}. 

handle_event(arrival, State) ->
    sim_proc:println("Arrived"),
    In_the_air_ = State#state.in_the_air + 1,
    
    Runway_free_ = case State#state.runway_free of
                       true -> sim_proc:schedule(landed, ?R),
                               false;
                       false -> false
                   end,
    {ok, State#state{in_the_air = In_the_air_, runway_free = Runway_free_}};
handle_event(landed, State) ->
    sim_proc:println("Landed"),
    In_the_air_ = State#state.in_the_air - 1,
    On_the_ground_ = State#state.on_the_ground + 1,
    sim_proc:schedule(departure, ?G),
    Runway_free_ = case In_the_air_ > 0 of
                       true -> sim_proc:schedule(landed, ?R),
                               false;
                       false -> true
                   end,
    {ok, State#state{in_the_air = In_the_air_, on_the_ground = On_the_ground_, runway_free = Runway_free_}};
handle_event(departure, State) ->
    sim_proc:println("Departed"),
    On_the_ground_ = State#state.on_the_ground - 1,
    sim_proc:schedule(ord, arrival, 4),

    {ok, State#state{on_the_ground = On_the_ground_}};
handle_event(stop, State) ->
    {stop, State}.

terminate(normal, _State) ->
    sim_proc:println("Finished simulation");
    
terminate(timeout, _State) ->
    sim_proc:println("Timeout reached").

handle_info(_Info, State) ->
    {noreply,State}.

code_change(_OldVsn, State, _Extra) -> 
    {ok, State}.

