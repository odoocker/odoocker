-- Ghost tenant databases + least-privilege users.
-- __PLACEHOLDER__ values substituted at boot by cloud-init (never committed).
CREATE DATABASE IF NOT EXISTS ghost_hub;
CREATE DATABASE IF NOT EXISTS ghost_goldberry;
CREATE DATABASE IF NOT EXISTS ghost_ggg;
CREATE DATABASE IF NOT EXISTS ghost_nursery;

CREATE USER IF NOT EXISTS 'ghost_hub'@'%' IDENTIFIED BY '__MYSQL_GHOST_HUB_PASSWORD__';
CREATE USER IF NOT EXISTS 'ghost_goldberry'@'%' IDENTIFIED BY '__MYSQL_GHOST_GOLDBERRY_PASSWORD__';
CREATE USER IF NOT EXISTS 'ghost_ggg'@'%' IDENTIFIED BY '__MYSQL_GHOST_GGG_PASSWORD__';
CREATE USER IF NOT EXISTS 'ghost_nursery'@'%' IDENTIFIED BY '__MYSQL_GHOST_NURSERY_PASSWORD__';

GRANT ALL PRIVILEGES ON ghost_hub.* TO 'ghost_hub'@'%';
GRANT ALL PRIVILEGES ON ghost_goldberry.* TO 'ghost_goldberry'@'%';
GRANT ALL PRIVILEGES ON ghost_ggg.* TO 'ghost_ggg'@'%';
GRANT ALL PRIVILEGES ON ghost_nursery.* TO 'ghost_nursery'@'%';
FLUSH PRIVILEGES;
