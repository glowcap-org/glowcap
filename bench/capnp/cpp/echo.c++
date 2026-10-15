// One Cap'n Proto RPC call round trip over loopback TCP: a client thread and
// a server thread, each on its own kj event loop, both parked between calls.
// run.sh generates echo.capnp.h and echo.capnp.c++ into the build directory
// and passes it with -I.

#include <capnp/rpc-twoparty.h>
#include <kj/async-io.h>
#include <kj/debug.h>

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <future>
#include <thread>
#include <vector>

#include <sched.h>

#include "echo.capnp.h"

namespace {

class EchoImpl final : public Echo::Server {
 public:
  kj::Promise<void> greet(GreetContext context) override {
    context.getResults().setGreeting("hello over the wire");
    return kj::READY_NOW;
  }

  kj::Promise<void> report(ReportContext context) override {
    int64_t sum = 0;
    auto samples = context.getParams().getSamples();
    for (auto sample : samples) sum += sample;
    auto results = context.getResults();
    results.setCount(static_cast<uint32_t>(samples.size()));
    results.setSum(sum);
    return kj::READY_NOW;
  }
};

constexpr const char* kSource = "sensor-17/humidity";
constexpr const char* kTags[8] = {"site:lab-3",   "rack:b2",         "unit:percent", "model:sht45",
                                  "fw:2.4.1",     "owner:facilities", "tier:gold",    "region:us-west"};
constexpr size_t kSampleCount = 64;
constexpr int64_t kAt = 1760400000;
constexpr uint32_t kExpectedCount = 64;
constexpr int64_t kExpectedSum = 22364704;

void printLine(const char* call, std::vector<int64_t>& samples, size_t calls, size_t warmup,
               bool pinned) {
  std::sort(samples.begin(), samples.end());
  int64_t total = 0;
  for (auto s : samples) total += s;
  const int64_t p50 = samples[samples.size() / 2];
  const int64_t p99 = samples[samples.size() * 99 / 100];
  const int64_t mean = total / static_cast<int64_t>(samples.size());
  const int64_t rps = static_cast<int64_t>(1000000000.0 * samples.size() / total);
  std::printf(
      "roundtrip transport=capnp-cpp call=%s calls=%zu warmup=%zu p50_ns=%lld p99_ns=%lld "
      "mean_ns=%lld rps=%lld mode=release busy_poll_us=0 pin=%s\n",
      call, calls, warmup, (long long)p50, (long long)p99, (long long)mean, (long long)rps,
      pinned ? "yes" : "no");
}

void pinTo(int core) {
  if (core < 0) return;
  cpu_set_t set;
  CPU_ZERO(&set);
  CPU_SET(core, &set);
  KJ_REQUIRE(sched_setaffinity(0, sizeof(set), &set) == 0, "sched_setaffinity");
}

}  // namespace

int main(int argc, char** argv) {
  bool smoke = false;
  int clientCore = -1;
  int serverCore = -1;
  for (int i = 1; i < argc; i++) {
    if (std::strcmp(argv[i], "--smoke") == 0) {
      smoke = true;
    } else if (std::sscanf(argv[i], "--pin=%d,%d", &clientCore, &serverCore) == 2) {
      // parsed into the cores above
    } else {
      std::fprintf(stderr, "unknown argument %s\n", argv[i]);
      return 2;
    }
  }
  const size_t calls = smoke ? 200 : 3000;
  const size_t warmup = smoke ? 50 : 300;

  std::promise<uint16_t> portPromise;
  std::promise<kj::Own<kj::CrossThreadPromiseFulfiller<void>>> stopPromise;
  auto portFuture = portPromise.get_future();
  auto stopFuture = stopPromise.get_future();

  std::thread serverThread([&] {
    pinTo(serverCore);
    auto io = kj::setupAsyncIo();
    auto addr = io.provider->getNetwork().parseAddress("127.0.0.1", 0).wait(io.waitScope);
    auto listener = addr->listen();
    portPromise.set_value(listener->getPort());
    capnp::TwoPartyServer server(capnp::Capability::Client(kj::heap<EchoImpl>()));
    auto accepting = server.listen(*listener);
    auto stop = kj::newPromiseAndCrossThreadFulfiller<void>();
    stopPromise.set_value(kj::mv(stop.fulfiller));
    stop.promise.wait(io.waitScope);
  });

  pinTo(clientCore);
  auto io = kj::setupAsyncIo();
  auto addr = io.provider->getNetwork()
                  .parseAddress("127.0.0.1", portFuture.get())
                  .wait(io.waitScope);
  auto stream = addr->connect().wait(io.waitScope);
  capnp::TwoPartyClient client(*stream);
  Echo::Client echo = client.bootstrap().castAs<Echo>();

  std::vector<int64_t> samples;
  samples.reserve(calls);
  for (size_t i = 0; i < warmup + calls; i++) {
    auto t0 = std::chrono::steady_clock::now();
    auto request = echo.greetRequest();
    request.setName("world");
    auto reply = request.send().wait(io.waitScope);
    auto greeting = reply.getGreeting();
    auto t1 = std::chrono::steady_clock::now();
    KJ_REQUIRE(greeting == "hello over the wire");
    if (i >= warmup) {
      samples.push_back(std::chrono::duration_cast<std::chrono::nanoseconds>(t1 - t0).count());
    }
  }

  const bool pinned = clientCore >= 0;
  printLine("greet", samples, calls, warmup, pinned);

  std::vector<int64_t> reportSamples;
  reportSamples.reserve(calls);
  int64_t input[kSampleCount];
  for (size_t i = 0; i < kSampleCount; i++) input[i] = 100000 + (int64_t)(i * 7919) % 900000;
  for (size_t i = 0; i < warmup + calls; i++) {
    auto t0 = std::chrono::steady_clock::now();
    auto request = echo.reportRequest();
    request.setSource(kSource);
    auto tags = request.initTags(8);
    for (unsigned j = 0; j < 8; j++) tags.set(j, kTags[j]);
    auto values = request.initSamples(kSampleCount);
    for (unsigned j = 0; j < kSampleCount; j++) values.set(j, input[j]);
    request.setAt(kAt);
    auto reply = request.send().wait(io.waitScope);
    uint32_t count = reply.getCount();
    int64_t sum = reply.getSum();
    auto t1 = std::chrono::steady_clock::now();
    KJ_REQUIRE(count == kExpectedCount && sum == kExpectedSum, count, sum);
    if (i >= warmup) {
      reportSamples.push_back(
          std::chrono::duration_cast<std::chrono::nanoseconds>(t1 - t0).count());
    }
  }

  stopFuture.get()->fulfill();
  serverThread.join();

  printLine("report", reportSamples, calls, warmup, pinned);
  return 0;
}
