This is a small script to setup traffic shaping on a router box for an ADSL
line with limited upload bandwidth.

# Installation

## Manual setup

The main traffic shaping script is `shaper.sh`:

    shaper.sh enp3s0 up    # Enables traffic shaping
    shaper.sh enp3s0 down  # Disables traffic shaping

## Automatic setup

Enabling traffic shaping automatically requires NetworkManager Dispatcher to
work. Just type `make install` to install everything, and make sure that the
dispatcher service is running.

## Zabbix monitoring

Included are 3 files for monitoring traffic statistics with
[Zabbix](http://zabbix.com) :

* `tstat` collects class statistics and performs class discovery
* `zabbix_userparams.conf` adds the required keys to a Zabbix Agent
* `zabbix_template.xml` adds a _Traffic shaping_ template that automatically
  adds items for every running traffic class defined in `tc_cls` using the
  `tstat` command.
