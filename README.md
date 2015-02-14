This is a small script to setup traffic shaping on a router box for an ADSL
line with limited upload bandwidth.

It does so by :

* Setting a larger priority for special TCP packets influencing flow control.
  Especially, TCP does not perform well if ACK packets are delayed, since it
  cannot estimate packet loss properly.

* Allowing some traffic (HTTP, SSH, DNS, ICMP) to have a higher priority than
  other, bulk traffic.

* All other kinds of packets go into the lowest priority mode: they can use the
  full link as long as nobody else is using it.
