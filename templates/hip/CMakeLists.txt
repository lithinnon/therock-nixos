cmake_minimum_required(VERSION 3.21)
project(hip-app LANGUAGES CXX HIP)

find_package(rocblas REQUIRED)

add_executable(hip-app main.hip)
target_link_libraries(hip-app PRIVATE roc::rocblas)
install(TARGETS hip-app)
