default:
	mkdir -p ebin/
	cp src/erlangsim.app.src ebin/erlangsim.app # simulate rebar behaviour
	erl -make									  # calls the Emakefile
	find . -name "*.[he]rl" -print | etags - # emacs TAGS

clean:
	rm -rf ebin
