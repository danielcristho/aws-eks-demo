import ray
import torch

RAY_HEAD_ADDRESS = "ray://10.21.79.111:10001"

try:
    ray.init(
        address=RAY_HEAD_ADDRESS,
        # ignore_reinit_error=True,
        # logging_level="debug",
    )
    print(f"Ray Client successfully connected to: {RAY_HEAD_ADDRESS}")

    @ray.remote(num_gpus=1)
    def gpu_task(x):
        print("GPU available on Worker?", torch.cuda.is_available())
        return x * 2

    result = ray.get(gpu_task.remote(21))
    print(f"Result: {result}")

except AssertionError as e:
    print(f"Connection or Task Execution Failed: {e}")
    print("Pastikan: 1. Ray Cluster sudah Running. 2. Service Account memiliki izin yang benar.")
finally:
    if ray.is_initialized():
        ray.shutdown()