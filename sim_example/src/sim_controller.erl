-module(sim_controller).
-behaviour(sim_cont).
-export([start_link/0, init/1]).

start_link() ->
    sim_cont:start_link({local, ?MODULE}, ?MODULE, [], []).

init(_Args) ->
    %% {ok, [{local, Name, Module},
    %%       {remote, Node, Name, Module}].
    {ok, [
          {local, lax, lax},
          {local, ord, ord},
          {local, abd, abd}
         ]
    }.
    % | ignore.
    % | {'EXIT', Reason}.

     
