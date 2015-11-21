docker run --name vm1 --rm -v $PWD:/u --privileged \
  -i -t marcelwiget/snabbvm:latest \
  -u user_data.txt \
  http://download.cirros-cloud.net/0.3.4/cirros-0.3.4-x86_64-disk.img \
  0000:05:00.0
