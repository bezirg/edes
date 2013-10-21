-module(sim_example_app).
-behaviour(application).
-export([start/2, stop/1]).

start(_Type, _Args) ->
    sim_controller:start_link(),
    {ok, self()}.
stop(_State) ->
    ok.
