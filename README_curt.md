## howto
```
# 1) 작업 디렉터리: 원본은 그대로 두고 images/ 만 심볼릭 링크
mkdir -p /data/dataset/garage_ws
ln -sfn /data/dataset/garage /data/dataset/garage_ws/images

# 2) SfM  (입력과 출력이 같은 디렉터리)
spirula sfm auto /data/dataset/garage_ws -o /data/dataset/garage_ws --quality high

# 3) 학습
cd /data/dataset/garage_ws
spirula train --data /data/dataset/garage_ws \
       --train-resolution-divisor 2 \
       --num-iterations 30000 \
       --keep-viewer-alive 0 \
       --output-dir-prefix /data/dataset/garage_ws/outputs \
       --output-dir-name high-30k

```
