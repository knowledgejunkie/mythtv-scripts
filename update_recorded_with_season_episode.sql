-- update_recorded_with_season_episode.sql
--
-- * updated version of script posted to mythtv-dev by Torbjörn Jansson
--   on 2012/04/30: http://www.gossamer-threads.com/lists/mythtv/dev/515755#515755
--
-- * tested on MythTV 0.27 with tv_grab_uk_rt sourced listings which populates
--   recordedprogram.syndicatedepisodenumber for many programmes
--
-- Nick Morrott <knowledgejunkie.gmail.com>

UPDATE recorded, (
    SELECT
        chanid,
        starttime,

        -- as of MythTV 0.27, syndicatedepisodenumber format is 'E4S9' or 'S1' or 'E123'
        IF(INSTR(syndicatedepisodenumber,'S')>0,
            SUBSTRING(syndicatedepisodenumber,INSTR(syndicatedepisodenumber,'S')+1,99),
            0
        ) AS s,

        IF(INSTR(syndicatedepisodenumber,'E')>0,
            IF(INSTR(syndicatedepisodenumber,'S')>0,
                SUBSTRING(syndicatedepisodenumber,2,INSTR(syndicatedepisodenumber,'S')-2),
                SUBSTRING(syndicatedepisodenumber,INSTR(syndicatedepisodenumber,'E')+1,99)
            ),
            0
        ) AS e
    FROM
        recordedprogram
    WHERE
        LENGTH(syndicatedepisodenumber) > 0
    ) AS rp SET season = rp.s, episode = rp.e
WHERE
    recorded.chanid = rp.chanid
    AND recorded.progstart = rp.starttime
    AND recorded.season = 0
    AND recorded.episode = 0
