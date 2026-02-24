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
pbsnodes -a | awk -v GREEN="$GREEN" -v RED="$RED" -v BLUE="$BLUE" -v YELLOW="$YELLOW" -v NC="$NC" '
/^[^ ]/ {
  node=$1
}

/^ *state =/ {
  state=$3
  total++

  if (state ~ /free/) {
    free++
  }
  else if (state ~ /job-exclusive|job-busy/) {
    busy++
  }
  else if (state ~ /offline|down|unknown/) {
    down++
    down_nodes = down_nodes ? down_nodes ", " node : node
  }
  else {
    other++
  }
}

END {
  printf "\n  NODE STATUS SUMMARY  \n"
  printf "  " GREEN "  TOTAL NODES : %d" NC "\n", total 
  printf "  " BLUE "  FREE        : %3d" NC "\n", free
  printf "  " YELLOW "  BUSY        : %3d" NC "\n", busy

  if (down > 0)
    printf "  " RED "  DOWN/OFF    : %3d (%s)" NC "\n", down, down_nodes
  else
    printf "  " RED "  DOWN/OFF    : %3d" NC "\n", down

  if (other > 0)
    printf "  OTHER       : %3d\n", other
}'

###
  CPUS_PER_NODE=256
printf "\n  QUEUE STATUS SUMMARY  \n"

qstat -Qf | awk -v CPN=$CPUS_PER_NODE '
  /^Queue:/ {
    queue = $2
    total_jobs = 0
    enabled = "False"
    started = "False"
    def_ncpus = 0
    used_ncpus = 0
  }

  /total_jobs =/               { total_jobs = $3 }
  /default_chunk.ncpus =/      { def_ncpus = $3 }
  /resources_assigned.ncpus =/ { used_ncpus = $3 }
  /enabled =/                  { enabled = $3 }
  /started =/                  { started = $3 }

  /^$/ {
    if (queue != "") {

      free_cpus  = def_ncpus - used_ncpus
      if (free_cpus < 0) free_cpus = 0

      free_nodes = int(free_cpus / CPN)
      active     = (enabled=="True" && started=="True") ? 1 : 0

      # active vem PRIMEIRO (chave de ordenação)
      printf "%1d %-12s %5d %7d %5d\n",
             active, queue, total_jobs, free_cpus, free_nodes
    }
  }
' | sort -k1,1nr -k5,5nr | while read active queue jobs free_cpus free_nodes; do

    if [ "$active" -eq 1 ]; then
      # testa permissão REAL
      echo "sleep 1" | qsub -q "$queue" -o /dev/null -e /dev/null >/dev/null 2>&1
      if [ $? -eq 0 ]; then
        perm="OK"
      else
        perm="${RED}Fila restrita${NC}"
      fi

      printf "    %-12s %-2s  \n" "$queue" "$perm" 
    else
      printf "    %-12s ERROR   fila desativada\n" "$queue"
    fi
done
 
############################################################################################################
echo ""
echo "3) Lustre, Home and NetAPP Filesystems "
echo ""
 
mount > /dev/null 2>&1
mount | grep "/oper/dados " > /dev/null 2>&1
df -h | grep "/oper/dados " > /dev/null 2>&1
ls -ltr /oper/dados > /dev/null 2>&1
#lustre
if lustre=$(mount | grep lustre | awk '{print $3, $5}') && size_lustre=$( df -h | grep lustre | awk '{print $2, $3, $4, $5}') \
&& timeout 5 touch /p/projetos/monan_adm/.writing_$$ 2>/dev/null && rm -f /p/projetos/monan_adm/.writing_$$; then
  echo -e "   ${lustre}        ---- ${GREEN} Montagem e escrita OK ${NC} --- ${YELLOW} ${size_lustre} ${NC}"  
else
  echo -e "   "${lustre}  ---- ${RED}  Filesystem com ERRO ${NC}
fi
#home
if home=$(mount | grep HOME | awk '{print $3, $5}') && size_home=$(df -h | grep HOME | awk '{print $2, $3, $4, $5}') \
&& timeout 5 touch "$HOME/.writing_$$" 2>/dev/null && rm -f "$HOME/.writing_$$"; then
  echo -e "   ${home}   ---- ${GREEN} Montagem e escrita OK ${NC} --- ${YELLOW} ${size_home} ${NC}"
else 
  echo -e "   "${home}  ---- ${RED} Filesystem com ERRO ${NC}
fi 
#netapp
if netapp=$(mount | grep "/oper/dados " | awk '{print $3, $5}') && size_netapp=$(df -h | grep "/oper/dados " | awk '{print $2, $3, $4, $5}') \
&& stat /oper/dados > /dev/null 2>&1 ; then
  echo -e "   ${netapp}  ---- ${GREEN} Montagem e leitura OK ${NC} ---  ${YELLOW} ${size_netapp} ${NC}"
else
   echo -e "   ${netapp}  ---- ${RED} Filesystem com ERRO ${NC}"
fi

############################################################################################################
echo ""
echo "4) Ecflow System check"
echo ""
flow=ian02

porta=$(ssh -o  BatchMode=yes ${flow} pgrep -a ecflow_server | awk -F'--port=' '{print $2}' | tail -1)


if [ -n "$porta" ] && ssh -o BatchMode=yes ${flow} 'module load ecflow; ecflow_client --host='${flow} '--port='${porta}' --ping' >/dev/null 2>&1; then
    echo -e "   Ecflow Server ------------------ ${GREEN}OK${NC}"
    ssh  -o BatchMode=yes ${flow} 'module load ecflow; ecflow_client --host='${flow}' --port='${porta}' --stats  | grep -E "Status|Port|Host|Up"' | tail -4
else
    echo -e "   Ecflow Server ------------------ ${RED}ERRO${NC}"
fi

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
    echo -e "   Modules System ---------- ${GREEN}OK${NC}"
else
    echo -e "   Modules System ---------- ${RED}ERRO${NC}"
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

