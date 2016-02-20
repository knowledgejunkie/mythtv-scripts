# mythtv-scripts
Scripts and utilities for managing MythTV

## update_recorded_with_season_episode.sql

This script parses recordedprogram.syndicatedepisodenumber and updates
recorded.season and recorded.episode appropriately.
    
I don't use metadata grabbers and the XMLTV/tv_grab_uk_rt listings
grabber provides consistent numbering for many programmes.

## mythlink-custom.pl

A customised version of mythlink.pl that creates custom-formatted recording symlinks
for Children's TV, Movies, Radio and TV.
