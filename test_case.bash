#!/bin/bash 

#LOG="output_test_case.log"
#exec > >(tee -a "$LOG") 2>&1

# Colors:
#
export GREEN=$'\033[1;32m'  # Green
export RED=$'\033[1;31m'    # RED
export NC=$'\033[0m'        # no color 
export BLUE=$'\033[01;34m'  # Blue
export YELLOW=$'\033[1;33m'

############################################################################################################
echo ""
echo "========= INICIANDO TEST_CASE ========="
echo ""
echo "1) Login nodes check (ping, ssh e uptime) "
echo ""

for n in ian{01..07}; do
     [[ "$n" == "ian03" || "$n" == "ian07" ]] && ssh_port=2223 || ssh_port=22
    if ping -c1 -W1 "$n" &>/dev/null && timeout 5 ssh -o BatchMode=yes -o ConnectTimeout=3 -p ${ssh_port} "$n" "true" &>/dev/null; then
      bott=$(ssh -q -T -p ${ssh_port} $n last reboot | grep reboot | awk '{print $2, $3, $5, $6, $7, $8}')
      upt=$(ssh -q -T -p ${ssh_port} $n uptime | grep up | awk -F',' '{print $1}' | awk '{print $2, $3, $4}' )
      echo -e "     $n ---------- ${GREEN}OK ${NC} ""${upt} -- ${YELLOW}${bott}${NC}"" (Porta = ${ssh_port})"  
    else
        echo "     $n ----------${RED} Inacessivel${NC}"
    fi
done

############################################################################################################
echo ""
echo "2) Nodes and Queues (PBS) "

# ================= USERS =================
qstat -f | awk '
/^Job Id:/ {
    user=""
    queue=""
    state=""
    cpus=0
    nodes=0
    walltime="--:--:--"
}

/Job_Owner =/ {
    split($3,u,"@")
    user=u[1]
}

/ queue =/ { queue=$3 }
/ job_state =/ { state=$3 }
/Resource_List.ncpus =/ { cpus=$3 }
/Resource_List.nodect =/ { nodes=$3 }
/resources_used.walltime =/ { walltime=$3 }

/^$/ {
    if (user != "" && queue != "") {
        key=user FS queue

        jobs[key]++
        total_cpus[key]+=cpus
        total_nodes[key]+=nodes

        if (state == "R")
            run_jobs[key]++
        else
            last_state[key]=state

        if (walltime > max_walltime[key])
            max_walltime[key]=walltime
    }
}

END {
    printf "\n=== USERS STATUS SUMMARY (PBS) ===\n"
    for (k in jobs) {
        split(k,a,FS)
        user=a[1]
        queue=a[2]

        if (run_jobs[k] > 0)
            jobstr = run_jobs[k] " jobs (r)"
        else
            jobstr = jobs[k] " job(" tolower(last_state[k]) ")"

        wt = (max_walltime[k] != "" ? max_walltime[k] : "--:--:--")

        printf "%-16s %-10s %-14s %10d cpus %8d nodes %10s\n",
               user, queue, jobstr,
               total_cpus[k], total_nodes[k], wt
    }
}'

# ================= NODES =================
pbsnodes -a | awk -v GREEN="$GREEN" -v RED="$RED" -v BLUE="$BLUE" -v YELLOW="$YELLOW" -v NC="$NC" '
/^[^ ]/ { node=$1 }

/^ *state =/ {
  state=$3
  total++

  if (state ~ /free/) free++
  else if (state ~ /job-exclusive|job-busy/) busy++
  else if (state ~ /offline|down|unknown/) {
    down++
    down_nodes = down_nodes ? down_nodes ", " node : node
  }
  else other++
}

END {
  printf "\n  NODE STATUS SUMMARY\n"
  printf "  " GREEN "  TOTAL NODES : %d" NC "\n", total
  printf "  " BLUE  "  FREE        : %3d" NC "\n", free
  printf "  " YELLOW"  BUSY        : %3d" NC "\n", busy

  if (down > 0)
    printf "  " RED "  DOWN/OFF    : %3d (%s)" NC "\n", down, down_nodes
  else
    printf "  " RED "  DOWN/OFF    : %3d" NC "\n", down

  if (other > 0)
    printf "  OTHER       : %3d\n", other
}'

# ================= QUEUES =================
CPUS_PER_NODE=256

read total_nodes free_nodes <<< $(pbsnodes -a | awk '
/^ *state =/ {
  total++
  if ($3 ~ /free/) free++
}
END { print total, free }')

free_cpus=$((free_nodes * CPUS_PER_NODE))

printf "\n=== QUEUE STATUS SUMMARY (PBS) ===\n\n"

printf "${BLUE}Cluster Livre: %d CPUs (%d nós)${NC}\n\n" "$free_cpus" "$free_nodes"

# 🔥 calcula largura da maior fila
maxlen=$(qstat -Qf | awk '/^Queue:/ {print length($2)}' | sort -nr | head -1)

qstat -Qf | awk '
  /^Queue:/ {
    queue = $2
    total_jobs = 0
    enabled = "False"
    started = "False"
  }

  /total_jobs =/ { total_jobs = $3 }
  /enabled =/    { enabled = $3 }
  /started =/    { started = $3 }

  /^$/ {
    if (queue != "") {
      active = (enabled=="True" && started=="True") ? 1 : 0
      printf "%1d %s %d\n", active, queue, total_jobs
    }
  }
' | sort -k1,1nr | while read active queue jobs; do

    if [ "$active" -eq 1 ]; then

      echo "sleep 5" | qsub -q "$queue" -o /dev/null -e /dev/null >/dev/null 2>&1

      if [ $? -eq 0 ]; then
        perm="OK"
      else
        perm="NO"
      fi

      printf "%-*s %-3s %5d job(s)\n" \
             "$maxlen" "$queue" "$perm" "$jobs"

    else
      printf "%-*s ERROR fila desativada\n" \
             "$maxlen" "$queue"
    fi

done
 
############################################################################################################
echo ""
echo "3) Lustre, Home and NetAPP Filesystems "
echo ""

# largura das colunas
FMT="   %-25s ---- %-30s --- %-25s\n"

mount > /dev/null 2>&1
mount | grep "/oper/dados " > /dev/null 2>&1
df -h | grep "/oper/dados " > /dev/null 2>&1
ls -ltr /oper/dados > /dev/null 2>&1

# lustre
if lustre=$(mount | grep lustre | awk '{print $3, $5}') \
&& size_lustre=$(df -h /p | awk 'NR==2 {printf "%s   (%s / %s)", $5, $3, $2}') \
&& timeout 5 touch /p/projetos/monan_adm/.writing_$$ 2>/dev/null && rm -f /p/projetos/monan_adm/.writing_$$; then

  printf "$FMT" "$lustre" "${GREEN}Montagem e escrita OK${NC}" "${YELLOW}$size_lustre${NC}"

else
  printf "$FMT" "$lustre" "${RED}Filesystem com ERRO${NC}" "-"
fi

# home
if home=$(mount | grep HOME | awk '{print $3, $5}') \
&& size_home=$(df -h $HOME | awk 'NR==2 {printf "%s   (%s / %s)", $5, $3, $2}') \
&& timeout 5 touch "$HOME/.writing_$$" 2>/dev/null && rm -f "$HOME/.writing_$$"; then

  printf "$FMT" "$home" "${GREEN}Montagem e escrita OK${NC}" "${YELLOW}$size_home${NC}"

else 
  printf "$FMT" "$home" "${RED}Filesystem com ERRO${NC}" "-"
fi 

# netapp
if netapp=$(mount | grep "/oper/dados " | awk '{print $3, $5}') \
&& size_netapp=$(df -h /oper/dados | awk 'NR==2 {printf "%s   (%s / %s)", $5, $3, $2}') \
&& stat /oper/dados > /dev/null 2>&1 ; then

  printf "$FMT" "$netapp" "${GREEN}Montagem e leitura OK${NC}" "${YELLOW}$size_netapp${NC}"

else
  printf "$FMT" "$netapp" "${RED}Filesystem com ERRO${NC}" "-"
fi


echo ""
gid=8159
mnt=/p

# pega nome do grupo
group_name=$(getent group $gid | cut -d: -f1)

# cores


quota_output=$(lfs quota -p $gid $mnt 2>/dev/null)

if [ -z "$quota_output" ]; then
  echo -e "   Lustre Quota ($group_name) ----------- ${RED}ERRO${NC}"
else
  echo -e "   Lustre Quota ($group_name) ----------- ${GREEN}OK${NC}"

  echo "$quota_output" | awk -v GREEN="$GREEN" -v YELLOW="$YELLOW" -v RED="$RED" -v NC="$NC" '
  function human(x) {
    if (x > 1024^3) return sprintf("%.1f TB", x/1024/1024/1024)
    else if (x > 1024^2) return sprintf("%.1f GB", x/1024/1024)
    else return sprintf("%.1f MB", x/1024)
  }

  function human_files(x) {
    if (x > 1e6) return sprintf("%.1fM", x/1e6)s
    else if (x > 1e3) return sprintf("%.1fk", x/1e3)
    else return x
  }

  function color(pct) {
    if (pct >= 90) return RED
    else if (pct >= 80) return YELLOW
    else return GREEN
  }

  NR==3 {
    space_used=$2
    space_limit=$4
    files_used=$6
    files_limit=$8

    if (space_limit > 0)
      space_pct=int((space_used/space_limit)*100)
    else
      space_pct=0

    if (files_limit > 0)
      files_pct=int((files_used/files_limit)*100)
    else
      files_pct=0

    c1=color(space_pct)
    c2=color(files_pct)

    printf "   Space Usage                         %s%d%%%s   (%s / %s)\n", c1, space_pct, NC, human(space_used), human(space_limit)
    printf "   Files Usage                          %s%d%%%s   (%s / %s files)\n", c2, files_pct, NC, human_files(files_used), human_files(files_limit)
  }'
fi




############################################################################################################



echo ""
echo "4) Ecflow System check"
echo ""

hosts="ian02 ian05"

for flow in $hosts; do

  echo "Host: $flow"
  
  ssh -o BatchMode=yes $flow '
  pids=$(pgrep ecflow_server)

  found=0

  if [ -z "$pids" ]; then
    echo "   Ecflow Server ------------------ ERRO"
    exit 0
  fi

  for pid in $pids; do

    user=$(ps -o user= -p $pid)

    # 🔥 filtro de usuário
    if [[ "$user" != "monan" && "$user" != "ioper" ]]; then
      continue
    fi

    found=1

    port=$(ps -fp $pid | grep -oP "(?<=--port=)[0-9]+")
    start=$(ps -p $pid -o lstart=)
    etime=$(ps -p $pid -o etimes=)
    days=$((etime/86400))
    hostt=$(hostname)

    echo "Host: ${hostt}"
    echo "   Ecflow Server ${YELLOW}$user${NC} ------------------------ OK"
    echo "   PID                                        $pid"
    echo "   Status                                     RUNNING"
    echo "   Host                                       '"$flow"'"
    echo "   Port                                       ${port:-UNKNOWN}"
    echo "   Up --------------------------------------- ${days} days   $(date -d "$start" "+%Y-%b-%d %H:%M:%S")"
    echo ""
    echo ""

  done

  # 🔥 se não encontrou nenhum dos usuários
  if [ $found -eq 0 ]; then
    echo "   Ecflow Server ------------------ ERRO"
  fi

  ' 2>/dev/null | awk '/Ecflow Server/{flag=1} flag'

done




############################################################################################################
echo ""
echo "5) Internet Connection"
echo ""

if timeout 5 curl -Is https://github.com/monanadmin/convert_mpas.git >/dev/null 2>&1; then
    echo -e "   Github convert_mpas ---------- ${GREEN}OK${NC}"
else
    echo -e "   Github convert_mpas ---------- ${RED}ERRO${NC}"
fi

if timeout 5 curl -Is https://github.com/monanadmin/MONAN-Model.git >/dev/null 2>&1; then
    echo -e "   Github Monan-Model  ---------- ${GREEN}OK${NC}"
else
    echo -e "   Github Monan-Model  ---------- ${RED}ERRO${NC}"
fi

if timeout 5 curl -Is https://www2.mmm.ucar.edu/projects/mpas/ >/dev/null 2>&1; then
    echo -e "   Ucar MESH  ------------------- ${GREEN}OK${NC}"
else
    echo -e "   Ucar MESH  ---------- ${RED}ERRO${NC}"
fi

############################################################################################################
echo ""
echo "6) Modules"
echo ""

if module -t avail >/dev/null 2>&1 && module load cray-parallel-netcdf/1.12.3.15 && module load cray-netcdf/4.9.0.15 && module load cray-hdf5/1.14.3.3 \
&& module load craype-x86-turin && ssh -o BatchMode=yes ${flow} module load ecflow >/dev/null 2>&1 ; then
    echo -e "   Modules System --------------- ${GREEN}OK${NC}"
else
    echo -e "   Modules System --------------- ${RED}ERRO${NC}"
fi
echo ""
echo "========= FIM DO TEST_CASE =========="
echo ""
exit

INTEL
# Load modules:
module purge
module load PrgEnv-intel
module load craype-x86-turin
module load cray-hdf5/1.14.3.3
module load cray-netcdf/4.9.0.15
module load cray-parallel-netcdf/1.12.3.15
module load grads/2.2.1.oga.1
module load cdo/2.4.2
module load METIS/5.1.0
module load cray-pals


GNU
# Load modules:
module purge
module load PrgEnv-gnu
module load craype-x86-turin
module load xpmem/0.2.119-1.3_gef379be13330
module load cray-hdf5/1.14.3.3
module load cray-netcdf/4.9.0.15
module load cray-parallel-netcdf/1.12.3.15
module load grads/2.2.1.oga.1
module load cdo/2.4.2
module load METIS/5.1.0
module load cray-pals




echo "===== COMPILERS ====="
ftn --version
cc --version
CC --version


echo "===== MPI ====="
module load cray-pals
which mpirun
mpirun --version
echo "CRAY_MPICH_VERSION=$CRAY_MPICH_VERSION"

echo "===== PBS ====="
qstat --version 2>&1
which qsub
which qstat

