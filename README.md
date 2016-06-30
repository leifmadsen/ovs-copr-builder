# ovs-copr-builder
Script to make it simpler to submit a new build from OVS git checkout to copr.
Mostly used by myself, but maybe you'll find this useful too.

## Running from cronjob
I run this script from a cronjob twice a day with the following command:

```
15 0,12 * * * /usr/bin/bash /home/lmadsen/src/github/openvswitch/buildrpm.sh -p
/home/lmadsen/src/github/openvswitch -c
```
