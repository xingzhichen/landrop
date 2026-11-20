cmake_minimum_required(VERSION 3.22.1)
project(landrop_secure_fs LANGUAGES CXX)

add_library(landrop_secure_fs SHARED secure_fs_jni.cpp)
target_compile_features(landrop_secure_fs PRIVATE cxx_std_17)
target_compile_definitions(landrop_secure_fs PRIVATE _FILE_OFFSET_BITS=64)
target_compile_options(landrop_secure_fs PRIVATE -Wall -Wextra)
