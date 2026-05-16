cmake_minimum_required(VERSION 3.5.0)
project(scrcpy_capture)

set(NATIVERENDER_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR})

include_directories(${NATIVERENDER_ROOT_PATH}
                    ${NATIVERENDER_ROOT_PATH}/include)

add_library(scrcpy_capture SHARED
    napi_init.cpp
    ScreenCaptureEncoder.cpp
    TcpServer.cpp)

target_link_libraries(scrcpy_capture PUBLIC
    libace_napi.z.so
    libnative_avscreen_capture.so
    libnative_media_core.so
    libnative_media_codecbase.so
    libnative_media_venc.so
    libnative_buffer.so
    libnative_window.so
    libpixelmap.so
    libimage_packer.so
    libhilog_ndk.z.so)
