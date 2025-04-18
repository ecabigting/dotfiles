#!/bin/bash
#docker system prune -af --volumes &
#docker volume rm $(docker volume ls -q)

docker system prune -af &&
  docker image prune -af &&
  docker system prune -af --volumes &&
  docker system df
