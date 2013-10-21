default:
	mkdir -p ebin/
	cp src/sim_example.app.src ebin/sim_example.app # simulate rebar behaviour
	erl -make									  # calls the Emakefile
	find . -name "*.[he]rl" -print | etags - # emacs TAGS

clean:
	rm -rf ebin
