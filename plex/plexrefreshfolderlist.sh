#!/bin/bash
#plexrefreshfolderlist.sh version 1.4

. "${HOME}/media/.config/cloud/cloud.conf"
. "$(dirname $0)/cloud.sh"
trap 'cleanup' 0 1 2 3 6

UNIONFSPATH="${HOME}/media"
RCLONELISTPATH="gcrypt:.cache/"
PLEXLISTPATH="$UNIONFSPATH/.cache/"
CACHE="${HOME}/.cache/"
LASTRUNFILE="${CACHE}/$SCRIPTNAME.lastrun"
RCLONECACEHOFFSET="1 minute"

if [[ ! -e $CACHE ]]; then mkdir -p $CACHE; fi

if [[ -f "$LASTRUNFILE" ]]; then
	LASTRUNTIME=$(date -r "$LASTRUNFILE")
	log "Last Run: ${LASTRUNTIME}"
else
	LASTRUNTIME=""
	log "Last Run: Never"
	touch -d "1 year ago" "$LASTRUNFILE"
fi

if [ $(lsb_release -r | awk '{ print $2 }') = 18.10 ] || [ $(lsb_release -r | awk '{ print $2 }') = 18.04  ] ;then
	#libcurl workaround for Ubuntu 18.x https://github.com/GitTools/GitVersion/issues/1508
	export LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libcurl.so.4
fi

if ! (systemctl is-active -q rclonemount) || ! (systemctl is-active -q plexmediaserver); then
    log "Rclone Mount/Plex Media Server not Active, exiting"
    exit 1
fi

SECTION="REFRESH_LIST_PATH"
# Refresh List Path
rclone rc vfs/refresh dir="$(echo "$PLEXLISTPATH" | sed -e s@${UNIONFSPATH}/@@)"
if [[ $? -eq 0 ]]; then
    log "SUCCESS: Rclone vfs/refresh folder $(echo "$PLEXLISTPATH" | sed -e s@${UNIONFSPATH}/@@)"
else
    log "ERROR: Rclone vfs/refresh folder $(echo "$PLEXLISTPATH" | sed -e s@${UNIONFSPATH}/@@) ERROR: $?"
fi

# POPULATE ARRAY WITH LIST FILES
readarray -t LISTFILES < <(find $PLEXLISTPATH -type f -iname "*files-to.list" -mmin +1 -newermt "$(date -d "$LASTRUNTIME - $RCLONECACEHOFFSET")")
# EXIT IF THERE ARE NO PLEX LIST FILES
if [ -z "$LISTFILES" ]; then
    log "No list files found"
else
    # COMBINE ALL LIST FILES IN TO LOCAL LIST FILE
    for LISTFILE in "${LISTFILES[@]}"
    do
        log "adding $LISTFILE"
        cat $LISTFILE >> ${CACHE}$TIMESTAMP-plex.list
        #FILE=$(basename "${LSITFILE}")
    done

    # POPULATE ARRAY WITH FILE PATHS PREPENDING UNIONFS PATH AND REMOVING FILE FOR PLEX MEDIA SCANNER (ONLY SUPPORTS FOLDERS)
    readarray -t MEDIAFILES < ${CACHE}$TIMESTAMP-plex.list
    for MEDIAFILE in "${MEDIAFILES[@]}"
    do
        MEDIAFOLDERS+=("$(dirname "${UNIONFSPATH}/${MEDIAFILE}")")
    done

    # PUPULATE ARRAY REMOVING DUPLICATES
    readarray -t MEDIAFOLDERS < <(printf "%s\n" "${MEDIAFOLDERS[@]}" | sort -u)
    log "Unique folders(${#MEDIAFOLDERS[@]}) found for Plex Media Scanner"

    # LOOP THROUGH EACH FOLDER
    for MEDIAFOLDER in "${MEDIAFOLDERS[@]}"
    do
        # REFRESH LOCAL CACHE FOR FOLDER 
        rclone rc vfs/refresh dir="$(echo "$MEDIAFOLDER" | sed -e s@${UNIONFSPATH}/@@)"
        if [[ $? -eq 0 ]]; then
                log "SUCCESS: Rclone vfs/refresh folder $MEDIAFOLDER"
        else
                log "ERROR: Rclone vfs/refresh folder $MEDIAFOLDER ERROR: $?"
        fi

        # EXECUTE PLEX MEDIA SCANNER FOR FOLDER
        log "Start Plex Media Scanner for folder: $MEDIAFOLDER"
        libraryfolder="$(echo $(echo "$MEDIAFOLDER" | sed -e s@${UNIONFSPATH}/@@) | cut -d '/' -f 1 | sed -e 's/ //g')"
        section_varname="${libraryfolder}SECTION"
        if [[ -d "$MEDIAFOLDER" ]] && [[ -n ${!section_varname} ]]; then
            ${PLEX_MEDIA_SERVER_DIR}/Plex\ Media\ Scanner \
            --scan --refresh --section "${!section_varname}" --directory "${MEDIAFOLDER}"
            if [[ $? -eq 0 ]]; then
                log "SUCCESS: Plex Media Scanner successful for media folder $MEDIAFOLDER"
            else
                log "ERROR: Error executing Plex Media Scanner ERROR: $?"
            fi
        elif [[ -z ${!section_name} ]]; then
                log "SKIP: No existing Plex Media Library Section found for media folder $MEDIAFOLDER"
        elif [[ ! -d "$MEDIAFOLDER" ]]; then
            log "SKIP: Plex Media Library folder $MEDIAFOLDER not found for scanner"
        fi
    done
    # ADD SUFFIX DONE TO THE FINISHED LIST
#    slack_message "Plex Media Scanner Completed" "${#FILES[@]} file/s imported into Plex Libraries" "$(cat "${CACHE}$TIMESTAMP-plex.list")" "$TIMESTAMP-plex.list" | tee -a "$LOGFILE"
    json=$(slack_message "Plex Media Scanner Completed" "" "" "${#MEDIAFILES[@]} file/s imported into Plex Libraries" "$HOSTNAME" "" "$SCRIPTNAME")
    thread_ts=$(echo $json | python -c 'import sys, json; print json.load(sys.stdin)["message"]["ts"]')
    slack_message "" "$TIMESTAMP-plex.list\n\`\`\`$(cat "${CACHE}$TIMESTAMP-plex.list")\`\`\`" "" "" "$HOSTNAME" "" "$SCRIPTNAME" $thread_ts

    log "Completed $TIMESTAMP-plex.list.done"
    mv ${CACHE}$TIMESTAMP-plex.list ${CACHE}$TIMESTAMP-plex.list.done

fi

SECTION="DELETED_ITEMS_CLEANUP"
# CLEANUP ONE DAY OLD DONE LIST FILES
find ${CACHE} -type f -mtime +1 -name '*.done' -delete

plex_cleanup

#sqlite3 /var/lib/plexmediaserver/Library/Application\ Support/Plex\ Media\ Server/Plug-in\ Support/Databases/com.plexapp.plugins.library.db "UPDATE metadata_items SET deleted_at = null"

touch -d "$START" "$LASTRUNFILE"
