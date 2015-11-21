docker run --name vm1 --rm -v $PWD:/u --privileged \
  -i -t marcelwiget/snabbvm:latest \
  -u user_data.txt \
  https://cloud-images.ubuntu.com/wily/current/wily-server-cloudimg-amd64-disk1.img \
  0000:05:00.0
