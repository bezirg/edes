default:
	mkdir -p ebin/
	cp src/sim_engine.app.src ebin/sim_engine.app # simulate rebar behaviour
	erl -make									  # calls the Emakefile
	find . -name "*.[he]rl" -print | etags - # emacs TAGS

clean:
	rm -rf ebin
