
set -x

${AGAVE_JOB_CALLBACK_RUNNING}

echo "TACC: job $SLURM_JOB_ID execution at: `date`"

# our node name
NODE_HOSTNAME=`hostname -s`
echo "TACC: running on node $NODE_HOSTNAME"

# confirm DCV server is alive
SERVER_TYPE="DCV"
DCV_SERVER_UP=`systemctl is-active dcvserver`
if [ $DCV_SERVER_UP != "active" ]; then
  echo "TACC:"
  echo "TACC: ERROR - could not confirm dcvserver active, systemctl returned '$DCV_SERVER_UP'"
  echo "TACC: ERROR - Please submit a consulting ticket at the TACC user portal"
  echo "TACC: ERROR - https://portal.tacc.utexas.edu/tacc-consulting/-/consult/tickets/create"
  echo "TACC:"
  echo "TACC: job $SLURM_JOB_ID execution finished at: `date`"
  ${AGAVE_JOB_CALLBACK_FAILURE}
  exit 1
fi

# create an X startup file in /tmp
# source xinitrc-common to ensure xterms can be made
# then source the user's xstartup if it exists
XSTARTUP="/tmp/dcv-startup-$USER"
cat <<- EOF > $XSTARTUP
#!/bin/sh

unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
. /etc/X11/xinit/xinitrc-common
EOF
if [ -x $HOME/.vnc/xstartup ]; then
  cat $HOME/.vnc/xstartup >> $XSTARTUP
else
  echo "exec startxfce4" >> $XSTARTUP
fi
chmod a+rx $XSTARTUP

# if X0 socket exists, then DCV will use a higher X display number and ruin our day
# therefore, cowardly bail out and appeal to an admin to fix the problem
if [ -f /tmp/.X11-unix/X0 ]; then
  echo "TACC:"
  echo "TACC: ERROR - X0 socket already exists. DCV script will fail."
  echo "TACC: ERROR - Please submit a consulting ticket at the TACC user portal"
  echo "TACC: ERROR - https://portal.tacc.utexas.edu/tacc-consulting/-/consult/tickets/create"
  echo "TACC:"
  echo "TACC: job $SLURM_JOB_ID execution finished at: `date`"
  ${AGAVE_JOB_CALLBACK_FAILURE}
  exit 1
fi

# create DCV session for this job
DCV_HANDLE="${AGAVE_JOB_ID}-session"
dcv create-session --owner ${AGAVE_JOB_OWNER} --init=$XSTARTUP $DCV_HANDLE
if ! `dcv list-sessions | grep -q ${AGAVE_JOB_ID}`; then
  echo "TACC:"
  echo "TACC: WARNING - could not find a DCV session for this job"
  echo "TACC: WARNING - This could be because all DCV licenses are in use."
  echo "TACC: WARNING - Failing over to VNC session."
  echo "TACC: "
  echo "TACC: If you rarely receive a DCV session using this script, "
  echo "TACC: please submit a consulting ticket at the TACC user portal:"
  echo "TACC: https://portal.tacc.utexas.edu/tacc-consulting/-/consult/tickets/create"
  echo "TACC: "

  SERVER_TYPE="VNC"
  VNCSERVER_BIN=`which vncserver`

  echo ${AGAVE_JOB_ID} | vncpasswd -f > vncp.txt

  # launch VNC session
  VNC_DISPLAY=`$VNCSERVER_BIN -geometry ${desktop_resolution} -rfbauth vncp.txt $@ 2>&1 | grep desktop | awk -F: '{print $3}'`
  echo "TACC: got VNC display :$VNC_DISPLAY"

  if [ x$VNC_DISPLAY == "x" ]; then
    echo "TACC: "
    echo "TACC: ERROR - could not find display created by vncserver: $VNCSERVER"
    echo "TACC: ERROR - Please submit a consulting ticket at the TACC user portal:"
    echo "TACC: ERROR - https://portal.tacc.utexas.edu/tacc-consulting/-/consult/tickets/create"
    echo "TACC: "
    echo "TACC: job $SLURM_JOB_ID execution finished at: `date`"
    exit 1
  fi
fi

if [ "x${SERVER_TYPE}" == "xDCV" ]; then
  LOCAL_PORT=8443  # default DCV port
#  DISPLAY=":0"
  export DISPLAY=:0
elif [ "x${SERVER_TYPE}" == "xVNC" ]; then
  LOCAL_PORT=`expr 5900 + $VNC_DISPLAY`
  #DISPLAY=":${VNC_DISPLAY}"
  export DISPLAY=:${VNC_DISPLAY}
else
  echo "TACC: "
  echo "TACC: ERROR - unknown server type '${SERVER_TYPE}'"
  echo "TACC: Please submit a consulting ticket at the TACC user portal"
  echo "TACC: https://portal.tacc.utexas.edu/tacc-consulting/-/consult/tickets/create"
  echo "TACC:"
  echo "TACC: job $SLURM_JOB_ID execution finished at: `date`"
  exit 1
fi
echo "TACC: local (compute node) ${SERVER_TYPE} port is $LOCAL_PORT"

LOGIN_PORT=`echo $NODE_HOSTNAME | perl -ne 'print (($2+1).$3.$1) if /c\d(\d\d)-(\d)(\d\d)/;'`
if `echo ${NODE_HOSTNAME} | grep -q c5`; then
    # on a c500 node, bump the login port
    LOGIN_PORT=$(($LOGIN_PORT + 400))
fi
echo "TACC: got login node ${SERVER_TYPE} port $LOGIN_PORT"


echo "TACC: Your ${SERVER_TYPE} session is now running!"

# Webhook callback url for job ready notification
# (notifications sent to INTERACTIVE_WEBHOOK_URL (i.e. https://3dem.org/webhooks/interactive/))`
INTERACTIVE_WEBHOOK_URL="${_webhook_base_url}interactive/"

# Wait a few seconds for good measure for the job status to update
sleep 3;
if [ "x${SERVER_TYPE}" == "xDCV" ]; then
  # create reverse tunnel port to login nodes.  Make one tunnel for each login so the user can just
  # connect to stampede2.tacc
  for i in `seq 4`; do
      ssh -q -f -g -N -R $LOGIN_PORT:$NODE_HOSTNAME:$LOCAL_PORT login$i
  done
  echo "TACC: Created reverse ports on Stampede2 logins"
  echo "TACC:          https://stampede2.tacc.utexas.edu:$LOGIN_PORT"
  curl -k --data "event_type=WEB&address=https://stampede2.tacc.utexas.edu:$LOGIN_PORT&owner=${AGAVE_JOB_OWNER}&job_uuid=${AGAVE_JOB_ID}" $INTERACTIVE_WEBHOOK_URL &
elif [ "x${SERVER_TYPE}" == "xVNC" ]; then
  # fire up websockify to turn the vnc session connection into a websocket connection
  WEBSOCKIFY_OUT=`/home1/00832/envision/websockify/run --cert=/home1/00832/envision/.viscert/vis.2015.04.pem -D 5902 localhost:$LOCAL_PORT`
  echo $WEBSOCKIFY_OUT

  WEBSOCKET_PORT=$(($LOGIN_PORT + 20000))
  #notifications sent to INTERACTIVE_WEBHOOK_URL
  curl -k --data "event_type=VNC&host=vis.tacc.utexas.edu&port=$WEBSOCKET_PORT&address=vis.tacc.utexas.edu:$LOGIN_PORT&password=${AGAVE_JOB_ID}&owner=${AGAVE_JOB_OWNER}" $INTERACTIVE_WEBHOOK_URL &
else
  # we should never get this message since we just checked this at LOCAL_PORT
  echo "TACC: "
  echo "TACC: ERROR - unknown server type '${SERVER_TYPE}'"
  echo "TACC: Please submit a consulting ticket at the TACC user portal"
  echo "TACC: https://portal.tacc.utexas.edu/tacc-consulting/-/consult/tickets/create"
  echo "TACC:"
  echo "TACC: job $SLURM_JOB_ID execution finished at: `date`"
  ${AGAVE_JOB_CALLBACK_FAILURE}
  exit 1
fi

# Warn the user when their session is about to close
# see if the user set their own runtime
#TACC_RUNTIME=`qstat -j $JOB_ID | grep h_rt | perl -ne 'print $1 if /h_rt=(\d+)/'`  # qstat returns seconds
#TACC_RUNTIME=`squeue -l -j $SLURM_JOB_ID | grep $SLURM_QUEUE | awk '{print $7}'` # squeue returns HH:MM:SS
TACC_RUNTIME=`squeue -j $SLURM_JOB_ID -h --format '%l'`
if [ x"$TACC_RUNTIME" == "x" ]; then
	TACC_Q_RUNTIME=`sinfo -p $SLURM_QUEUE | grep -m 1 $SLURM_QUEUE | awk '{print $3}'`
	if [ x"$TACC_Q_RUNTIME" != "x" ]; then
		# pnav: this assumes format hh:dd:ss, will convert to seconds below
		#       if days are specified, this won't work
		TACC_RUNTIME=$TACC_Q_RUNTIME
	fi
fi

# run an xterm and launch paraview for the user; execution will hold here

WORKDIR=${workdir}

module load TACC
ml python3 swr

echo "TACC: launching cellblender"
export DISPLAY
#python3 alignem_swift.py

#xterm -r -ls -geometry 80x24+10+10 -title '*** Exit this window to kill your interactive session ***' -e 'swr -t 8 paraview'

xterm -r -ls -geometry 80x24+10+10 -title '*** Exit this window to kill your interactive session ***' -e 'swr -t 16 /work2/projects/NeuroNex/3DEM/bin/Blender/Blender-2.79-CellBlender/blender'
 

#xterm -r -ls -geometry 80x24+10+10 -title '*** Exit this window to kill your interactive session ***' 

#xterm -r -ls -geometry 80x24+10+10 -title '*** Exit this window to kill your interactive session ***' 


echo "TACC: closing ${SERVER_TYPE} session"
if [ "x${SERVER_TYPE}" == "xDCV" ]; then
  dcv close-session ${DCV_HANDLE}
elif [ "x${SERVER_TYPE}" == "xVNC" ]; then
  vncserver -kill ${DISPLAY}
else
  # we should never get this message since we just checked this at LOCAL_PORT
  echo "TACC: "
  echo "TACC: ERROR - unknown server type '${SERVER_TYPE}'"
  echo "TACC: Please submit a consulting ticket at the TACC user portal"
  echo "TACC: https://portal.tacc.utexas.edu/tacc-consulting/-/consult/tickets/create"
  echo "TACC:"
  echo "TACC: job $SLURM_JOB_ID execution finished at: `date`"
  ${AGAVE_JOB_CALLBACK_FAILURE}
  exit 1
fi


# wait a brief moment so vncserver can clean up after itself
sleep 1

# remove X11 sockets so DCV will find :0 next time
find /tmp/.X11-unix -user $USER -exec rm -f '{}' \;

echo "TACC: job $SLURM_JOB_ID execution finished at: `date`"

rm -Rf bin lib qtlib
