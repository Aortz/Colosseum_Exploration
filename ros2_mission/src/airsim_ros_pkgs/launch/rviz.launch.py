import os

import launch
import launch_ros.actions
from ament_index_python.packages import get_package_share_directory


def generate_launch_description():

    pkg_share = get_package_share_directory('airsim_ros_pkgs')
    # Use the persistent point cloud configuration by default
    persistent_rviz_path = os.path.join(pkg_share, 'rviz/pointcloud_persistent.rviz')
    default_rviz_path = os.path.join(pkg_share, 'rviz/default.rviz')
    
    # Check if persistent config exists, fallback to default
    rviz_config = persistent_rviz_path if os.path.exists(persistent_rviz_path) else default_rviz_path

    ld = launch.LaunchDescription([
        launch_ros.actions.Node(
            package='rviz2',
            executable='rviz2',
            name='rviz2',
            arguments=['-d', rviz_config],
            output='screen'
        )
    ])
    return ld