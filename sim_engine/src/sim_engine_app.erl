-module(sim_engine_app).
-behaviour(application).
-export([start/2, stop/1]).

start(_Type, _Args) ->
    {ok, self()}.
stop(_State) ->
    ok.
