CC := g++
CFLAGS := -fPIC -shared -Wall -O2

all: libsynurang_test_cpp.so

libsynurang_test_cpp.so: backend.cc
	$(CC) $(CFLAGS) -o $@ backend.cc

clean:
	rm -f libsynurang_test_cpp.so
