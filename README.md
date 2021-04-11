# 🏠 home-server
A repository to detail and document the general plan for my home server. 

## 🖥️ specs  
OS: Ubuntu Server **(I don't particularly like this choice just because I think Arch has a larger install base for other tools I might need for a server (and Ubuntu has ads, boo), but because the server doesn't have too many demands (yet), this should do just fine)**  
CPU: Intel i5-3300 (4 cores @ 32.GHz)  
RAM: 16GB  
Motherboard: Veriton M6620G P21-A0    
GPU: N/A  
Main storage: 260GB HDD  
Seconday storage: 10TB HDD  
PSU: --  

## 🛠️ planning/staging area  
### Docker Best Practices   
From [servarr](https://wiki.servarr.com/Docker_Guide#The_Best_Docker_Setup):  
```TL; DR: An eponymous user per daemon and a shared group with a umask of 002. Consistent path definitions between all containers that maintains the folder structure. Using one volume for Sonarr, Radarr and Lidarr so the download folder and library folder are on the same file system which makes hard links and instant moves possible. And most of all, ignore most of the Docker image’s path documentation!```  
I have read this so many times and it still takes me a minute to fully understand what it means.  
Basically each Docker Container is its own user part of an overall docker group. This allows the containers to easily read and write files created by other containers but shield the containers from any outside program/file/folder.  
#### PUID/PGID
We will use an arbitrary 123 for our group ID (PGID) and assign each container a PUID from 9000 to (9000 + n).  

#### Permissions
For each containers corresponding folder (ex. ~/storage/media/tv for sonarr) we chown its owner to the PUID we set earlier and add it to our 123 docker PGID.  

#### folder overview
storage
├── torrents
│  ├── movies
│  ├── music
│  └── tv
├── usenet
│  ├── movies
│  ├── music
│  └── tv
└── media
   ├── movies
   ├── music
   ├── books
   └── tv

### Containers & Info  
  - netdata	 / **to view server hardware stats**
  - samba	 / **ftp for linux/Windows**
  - sonarr	 / **pvr for tv series**
  - radarr	 / **pvr for movies**
  - qbittorrent	  / **torrent client**
  - homeassistant	 / **for smart home development and management**
  - tautulli	 / **plex stats**
  - jackett	 / **torrent and usenet indexer**
  - requestrr	 / **chatbot (in discord) for requesting tv and movies**
  - filebot	 / **for managing and renaming media files**
  - dozzle	/ **docker container logs**
  - duplicati	 / **off-site and cloud backups**
  - lidarr	 / **pvr for music**
  - unpackerr	 / **this manages our sonarr/radarr/lidarr conatiners. technically, if we do every thing right, we wont need this container but I don't trust myself to do anything right**
  - codeserver	 / **remote vs code?? of course!**
  - youtubedl	 / **webui for YouTube DL**
  - cloudcmd	 / **filebrowser and shell**
  - pyload	 / **download client, might replace with jdownloader**
  - nextcloud	 / **Google Drive alternative **
  - openvpnas		/ **for routing containers through vpn**
  - mylar3	 / **pvr for comics**
  - nzbget	 / **usenet download client**
  - plex	 / **media player**
  - bazarr	 / **subtitle fetching**
  - heimdall	 / **dashboard for containers**
  - portainer	 / **conatiner management tool**
  - watchtower  / **automatically update conatiners**

### Docker .env Setup  

### Reverse Proxy

### Port Forwarding

### Home Assistant

### Other apps

## 🎬 Setup
## 🔐 Security
## 🔧 Mainenance

## 🔮 Future Upgrades
