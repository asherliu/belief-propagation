project(benchmark_openmp)

cmake_minimum_required(VERSION 2.8)
find_package(OpenMP REQUIRED)
find_package(LibXml2 REQUIRED)

set(CMAKE_C_FLAGS_DEBUG  "${CMAKE_C_FLAGS_DEBUG} ${OpenMP_C_FLAGS}")
set(CMAKE_C_FLAGS_RELEASE "-O3 ${OpenMP_C_FLAGS}")

add_executable(openmp_benchmark main.c ../bnf-parser/Parser.c ../bnf-parser/Lexer.c ../bnf-parser/expression.c ../graph/graph.c ../bnf-xml-parser/xml-expression.c)
include_directories(${LIBXML2_INCLUDE_DIR})
target_link_libraries(openmp_benchmark ${LIBXML2_LIBRARIES})