destdir = ""
prefix = ""

install:
	cp tux.sh ${destdir}/${prefix}/bin/tux
	chmod +x ${destdir}/${prefix}/bin/tux
	ROOT=${destdir} ${destdir}/${prefix}/bin/tux init