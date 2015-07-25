install: tc_cls tstat shaper.sh
	install tc_cls /etc/iproute2/tc_cls
	install tstat /usr/bin
	install shaper.sh /etc/NetworkManager/dispatcher.d/10-shaper.sh
