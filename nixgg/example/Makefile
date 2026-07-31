CXX ?= c++
CXXFLAGS ?= -O2 -Wall

OBJS := main.o util.o

hello: $(OBJS)
	$(CXX) $(OBJS) -o hello

%.o: %.cc
	$(CXX) $(CXXFLAGS) -c $< -o $@

clean:
	rm -f $(OBJS) hello

.PHONY: clean
