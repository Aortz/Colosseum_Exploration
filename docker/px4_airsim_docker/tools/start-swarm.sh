#!/bin/bash

# Delayed PX4 Swarm Management Script
# This script starts Docker containers without immediately running PX4 SITL

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
COMPOSE_FILE="$PROJECT_DIR/docker-compose.yml"

# Default container list (9 drones)
DEFAULT_CONTAINERS=(
    "px4-swarm-1-drone-1"
    "px4-swarm-1-drone-2" 
    "px4-swarm-1-drone-3"
    "px4-swarm-1-drone-4"
    "px4-swarm-1-drone-5"
    "px4-swarm-1-drone-6"
    "px4-swarm-1-drone-7"
    "px4-swarm-1-drone-8"
    "px4-swarm-1-drone-9"
)

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_header() {
    echo -e "${BLUE}[DELAYED SWARM]${NC} $1"
}

# Function to test connectivity to AirSim
test_connectivity() {
    local host="$1"
    local port="${2:-41451}"
    local timeout="${3:-3}"
    
    if command -v nc >/dev/null 2>&1; then
        if timeout "$timeout" nc -z "$host" "$port" 2>/dev/null; then
            return 0
        fi
    elif command -v telnet >/dev/null 2>&1; then
        if timeout "$timeout" bash -c "echo >/dev/tcp/$host/$port" 2>/dev/null; then
            return 0
        fi
    fi
    return 1
}

# Check WSL2 environment and detect dual IP configuration
detect_wsl2_dual_ip() {
    if grep -qi "microsoft" /proc/version 2>/dev/null; then
        print_status "WSL2 detected - checking dual IP configuration..."
        
        # Get WSL2 interface IP (Remote Control IP)
        REMOTE_IP=$(ip route show | grep "src" | awk '{print $NF}' | head -1)
        
        # Get default gateway (LocalHostIp)
        LOCAL_HOST_IP=$(ip route show | grep -i default | awk '{ print $3}')
        
        # Get current PX4_SIM_HOSTNAME from compose file
        if [[ -f "$COMPOSE_FILE" ]]; then
            CURRENT_SIM_IP=$(grep "PX4_SIM_HOSTNAME:" "$COMPOSE_FILE" | awk '{print $2}')
        fi
        
        print_status "Network Configuration:"
        print_status "  Remote Control IP (WSL2 interface): ${REMOTE_IP:-'Not detected'}"
        print_status "  LocalHostIp (PX4_SIM_HOSTNAME): ${CURRENT_SIM_IP:-'Not set'}"
        print_status "  Default Gateway: ${LOCAL_HOST_IP:-'Not detected'}"
        
        # Test connectivity to both IPs if they exist
        if [[ -n "$REMOTE_IP" ]]; then
            print_status "Testing connectivity via Remote IP ($REMOTE_IP)..."
            if test_connectivity "$REMOTE_IP" 41451; then
                print_status "✅ AirSim API accessible via Remote IP $REMOTE_IP:41451"
            else
                print_warning "⚠️  AirSim API not accessible via Remote IP $REMOTE_IP:41451"
            fi
        fi
        
        if [[ -n "$CURRENT_SIM_IP" && "$CURRENT_SIM_IP" != "$REMOTE_IP" ]]; then
            print_status "Testing connectivity via LocalHostIp ($CURRENT_SIM_IP)..."
            if test_connectivity "$CURRENT_SIM_IP" 41451; then
                print_status "✅ AirSim API accessible via LocalHostIp $CURRENT_SIM_IP:41451"
            else
                print_warning "⚠️  AirSim API not accessible via LocalHostIp $CURRENT_SIM_IP:41451"
                print_warning "   This is expected for dual IP setup - PX4 connects to LocalHostIp"
                print_warning "   Remote control uses the Remote IP ($REMOTE_IP)"
            fi
        fi
        
        # Export both IPs for use by other functions
        export WSL2_REMOTE_IP="$REMOTE_IP"
        export WSL2_LOCAL_HOST_IP="$LOCAL_HOST_IP"
        export PX4_SIM_HOSTNAME_CURRENT="$CURRENT_SIM_IP"
        
        # Note: We do NOT automatically update PX4_SIM_HOSTNAME anymore
        # This allows dual IP configuration where:
        # - PX4_SIM_HOSTNAME stays as LocalHostIp (e.g., 172.28.240.1)
        # - Remote control uses the actual WSL2 interface IP (e.g., 172.28.248.55)
        
    fi
}

# Function to start containers in delayed mode
start_containers() {
    local num_drones=${1:-9}
    
    print_header "Starting $num_drones containers in delayed mode..."
    detect_wsl2_dual_ip
    
    # Select containers to start
    local containers_to_start=()
    for ((i=0; i<num_drones && i<${#DEFAULT_CONTAINERS[@]}; i++)); do
        containers_to_start+=("${DEFAULT_CONTAINERS[$i]}")
    done
    
    print_status "Starting containers: ${containers_to_start[*]}"
    
    # Start the selected containers
    docker-compose -f "$COMPOSE_FILE" up -d "${containers_to_start[@]}"
    
    print_status "Waiting for containers to be ready..."
    sleep 5
    
    # Check status
    echo ""
    print_header "Container Status:"
    for container in "${containers_to_start[@]}"; do
        if docker ps | grep -q "$container"; then
            print_status "✅ $container - RUNNING (delayed mode)"
        else
            print_error "❌ $container - FAILED TO START"
        fi
    done
    
    echo ""
    print_header "Next Steps:"
    echo "• Containers are running but PX4 SITL is not started yet"
    echo "• Use '$0 run-px4 <container_name>' to start PX4 in specific container"
    echo "• Use '$0 run-all-px4' to start PX4 in all running containers"
    echo "• Use '$0 status' to check container status"
}

# Function to start PX4 in a specific container
run_px4_in_container() {
    local container_name="$1"
    
    if [[ -z "$container_name" ]]; then
        print_error "Container name required. Usage: $0 run-px4 <container_name>"
        return 1
    fi
    
    print_header "Starting PX4 SITL in container: $container_name"
    
    # Check if container is running
    if ! docker ps | grep -q "$container_name"; then
        print_error "Container '$container_name' is not running"
        return 1
    fi
    
    # Start PX4 SITL in the container using run_airsim_sitl.sh
    print_status "Executing PX4 SITL startup script..."
    docker exec -d "$container_name" bash -c '
        cd /px4_workspace/PX4-Autopilot
        
        # Check if the script is available (should be copied during container startup)
        if [ -f "./Scripts/run_airsim_sitl.sh" ]; then
            echo "🚀 Starting PX4 SITL with instance $PX4_INSTANCE..."
            
            # Set environment variables for this instance
            # Note: PX4_SIM_HOSTNAME should be set from compose file (no hardcoded fallback)
            export PX4_SIM_HOSTNAME=${PX4_SIM_HOSTNAME}
            export PX4_SIM_MODEL=${PX4_SIM_MODEL:-iris}
            
            # Show which IP is being used for debugging
            echo "🔗 Using PX4_SIM_HOSTNAME: $PX4_SIM_HOSTNAME"
            
            # Start PX4 SITL using the script
            ./Scripts/run_airsim_sitl.sh $PX4_INSTANCE
        else
            echo "❌ run_airsim_sitl.sh not found in ./Scripts/"
            echo "Container may not have started properly or script mounting failed"
            exit 1
        fi
    '
    
    sleep 2
    print_status "✅ PX4 SITL started in $container_name"
    print_status "Check logs with: $0 logs $container_name"
}

# Function to start PX4 in all running containers
run_px4_in_all_containers() {
    print_header "Starting PX4 SITL in all running containers..."
    
    local running_containers=()
    for container in "${DEFAULT_CONTAINERS[@]}"; do
        if docker ps | grep -q "$container"; then
            running_containers+=("$container")
        fi
    done
    
    if [[ ${#running_containers[@]} -eq 0 ]]; then
        print_error "No swarm containers are currently running"
        return 1
    fi
    
    print_status "Found ${#running_containers[@]} running containers"
    
    for container in "${running_containers[@]}"; do
        print_status "Starting PX4 in $container..."
        run_px4_in_container "$container"
        sleep 2  # Small delay between starts
    done
    
    print_status "✅ PX4 SITL started in all containers"
}

# Function to show container status
show_status() {
    print_header "Swarm Container Status:"
    
    local running_count=0
    local px4_running_count=0
    
    for container in "${DEFAULT_CONTAINERS[@]}"; do
        if docker ps | grep -q "$container"; then
            running_count=$((running_count + 1))
            
            # Check if PX4 is running in the container
            if docker exec "$container" pgrep -f "px4" > /dev/null 2>&1; then
                print_status "✅ $container - CONTAINER + PX4 RUNNING"
                px4_running_count=$((px4_running_count + 1))
            else
                print_warning "🟡 $container - CONTAINER ONLY (PX4 not started)"
            fi
        else
            print_error "❌ $container - NOT RUNNING"
        fi
    done
    
    echo ""
    print_header "Summary:"
    echo "• Running containers: $running_count/${#DEFAULT_CONTAINERS[@]}"
    echo "• PX4 instances: $px4_running_count/${#DEFAULT_CONTAINERS[@]}"
}

# Function to show logs for a container
show_logs() {
    local container_name="$1"
    local follow="${2:-false}"
    
    if [[ -z "$container_name" ]]; then
        print_error "Container name required. Usage: $0 logs <container_name> [follow]"
        return 1
    fi
    
    if [[ "$follow" == "follow" || "$follow" == "-f" ]]; then
        docker logs -f "$container_name"
    else
        docker logs --tail 50 "$container_name"
    fi
}

# Function to stop all containers
stop_containers() {
    print_header "Stopping all swarm containers..."
    docker-compose -f "$COMPOSE_FILE" down
    print_status "✅ All containers stopped"
}

# Function to restart containers in delayed mode
restart_containers() {
    local num_drones=${1:-9}
    print_header "Restarting containers in delayed mode..."
    stop_containers
    sleep 2
    start_containers "$num_drones"
}

# Function to test network connectivity
test_network_connectivity() {
    print_header "Network Connectivity Test"
    
    # Check if running in WSL2 and detect dual IP configuration
    detect_wsl2_dual_ip
    
    # Get current PX4_SIM_HOSTNAME from compose file
    if [[ -f "$COMPOSE_FILE" ]]; then
        CURRENT_IP=$(grep "PX4_SIM_HOSTNAME:" "$COMPOSE_FILE" | awk '{print $2}')
        print_status "Current PX4_SIM_HOSTNAME in compose file: $CURRENT_IP"
        
        if [[ -n "$CURRENT_IP" ]]; then
            print_status "Testing connectivity to $CURRENT_IP..."
            
            # Test AirSim API (port 41451)
            if test_connectivity "$CURRENT_IP" 41451; then
                print_status "✅ AirSim API (41451): ACCESSIBLE"
            else
                print_error "❌ AirSim API (41451): NOT ACCESSIBLE"
            fi
            
            # Test PX4 SITL ports (4561-4563)
            for port in 4561 4562 4563; do
                if test_connectivity "$CURRENT_IP" "$port"; then
                    print_status "✅ PX4 SITL ($port): ACCESSIBLE"
                else
                    print_warning "⚠️  PX4 SITL ($port): NOT ACCESSIBLE (may be normal if PX4 not started)"
                fi
            done
        fi
    else
        print_error "Docker compose file not found: $COMPOSE_FILE"
    fi
}

# Function to show current configuration
show_config() {
    print_header "Current Configuration"
    
    # Environment detection and dual IP configuration
    if grep -qi "microsoft" /proc/version 2>/dev/null; then
        print_status "Environment: WSL2 (Dual IP Configuration)"
        
        # Get both IPs using same logic as detect_wsl2_dual_ip
        REMOTE_IP=$(ip route show | grep "src" | awk '{print $NF}' | head -1)
        LOCAL_HOST_IP=$(ip route show | grep -i default | awk '{ print $3}')
        
        print_status "Remote Control IP (WSL2): ${REMOTE_IP:-'Not detected'}"
        print_status "LocalHostIp (Gateway): ${LOCAL_HOST_IP:-'Not detected'}"
    else
        print_status "Environment: Native Linux/Docker"
    fi
    
    # Compose file settings
    if [[ -f "$COMPOSE_FILE" ]]; then
        print_status "Compose file: $COMPOSE_FILE"
        CURRENT_IP=$(grep "PX4_SIM_HOSTNAME:" "$COMPOSE_FILE" | awk '{print $2}')
        print_status "PX4_SIM_HOSTNAME: ${CURRENT_IP:-'Not set'}"
    else
        print_error "Compose file not found: $COMPOSE_FILE"
    fi
    
    # Container status
    echo ""
    show_status
}

# Function to set PX4_SIM_HOSTNAME manually
set_sim_hostname() {
    local new_ip="$1"
    
    if [[ -z "$new_ip" ]]; then
        print_error "IP address required. Usage: $0 set-sim-ip <ip_address>"
        print_status "Common options:"
        print_status "  $0 set-sim-ip 172.28.240.1    # Use default gateway (LocalHostIp)"
        print_status "  $0 set-sim-ip 172.28.248.55    # Use WSL2 interface (Remote IP)"
        return 1
    fi
    
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        print_error "Docker compose file not found: $COMPOSE_FILE"
        return 1
    fi
    
    print_header "Setting PX4_SIM_HOSTNAME to $new_ip"
    
    # Update compose file
    sed -i "s/PX4_SIM_HOSTNAME: .*/PX4_SIM_HOSTNAME: $new_ip/g" "$COMPOSE_FILE"
    
    # Validate the change
    if grep -q "PX4_SIM_HOSTNAME: $new_ip" "$COMPOSE_FILE"; then
        print_status "✅ Updated PX4_SIM_HOSTNAME to $new_ip"
        
        # Test connectivity
        print_status "Testing connectivity to $new_ip..."
        if test_connectivity "$new_ip" 41451; then
            print_status "✅ AirSim API accessible at $new_ip:41451"
        else
            print_warning "⚠️  AirSim API not accessible at $new_ip:41451"
            print_warning "   Make sure AirSim is running and configured for this IP"
        fi
    else
        print_error "❌ Failed to update compose file"
    fi
}

# Function to access container shell
shell_access() {
    local container_name="$1"
    
    if [[ -z "$container_name" ]]; then
        print_error "Container name required. Usage: $0 shell <container_name>"
        return 1
    fi
    
    if ! docker ps | grep -q "$container_name"; then
        print_error "Container '$container_name' is not running"
        return 1
    fi
    
    print_status "Opening shell in $container_name..."
    docker exec -it "$container_name" /bin/bash
}

# Function to show help
show_help() {
    echo "Delayed PX4 Swarm Management Script"
    echo ""
    echo "Usage: $0 <command> [options]"
    echo ""
    echo "Commands:"
    echo "  start [num]          Start containers in delayed mode (default: 9 drones)"
    echo "  stop                 Stop all containers"
    echo "  restart [num]        Restart containers in delayed mode"
    echo "  status               Show container and PX4 status"
    echo "  run-px4 <container>  Start PX4 SITL in specific container"
    echo "  run-all-px4          Start PX4 SITL in all running containers"
    echo "  logs <container> [follow]  Show container logs"
    echo "  shell <container>    Open shell in container"
    echo "  test-connection      Test network connectivity to AirSim"
    echo "  show-config          Show current IP configuration (dual IP setup)"
    echo "  set-sim-ip <ip>      Set PX4_SIM_HOSTNAME to specific IP"
    echo "  help                 Show this help"
    echo ""
    echo "Examples:"
    echo "  $0 start 3                           # Start 3 containers"
    echo "  $0 run-px4 px4-swarm-1-drone-1      # Start PX4 in drone 1"
    echo "  $0 logs px4-swarm-1-drone-1 follow  # Follow logs for drone 1"
    echo "  $0 status                            # Check all container status"
    echo "  $0 show-config                       # Show dual IP configuration"
    echo "  $0 set-sim-ip 172.28.240.1          # Set LocalHostIp for simulation"
    echo "  $0 test-connection                   # Test both IP configurations"
}

# Main script logic
case "${1:-help}" in
    "start")
        start_containers "${2:-9}"
        ;;
    "stop")
        stop_containers
        ;;
    "restart")
        restart_containers "${2:-9}"
        ;;
    "status")
        show_status
        ;;
    "run-px4")
        run_px4_in_container "$2"
        ;;
    "run-all-px4")
        run_px4_in_all_containers
        ;;
    "logs")
        show_logs "$2" "$3"
        ;;
    "shell")
        shell_access "$2"
        ;;
    "test-connection")
        test_network_connectivity
        ;;
    "show-config")
        show_config
        ;;
    "set-sim-ip")
        set_sim_hostname "$2"
        ;;
    "help"|*)
        show_help
        ;;
esac