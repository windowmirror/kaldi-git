#!/bin/bash

# Copyright 2013  Johns Hopkins University (author: Daniel Povey)
#           2014  Tom Ko
# Apache 2.0

# This example script demonstrates how speed perturbation of the data helps the nnet training in the SWB setup.

. ./cmd.sh
set -e 
stage=1
train_stage=-10
use_gpu=true
# splice_indexes="layer0/-4:-3:-2:-1:0:1:2:3:4 layer2/-5:-3:3"
splice_indexes="layer0/-2:-1:0:1:2 layer1/-1:2 layer2/-3:3 layer3/-7:2"
common_egs_dir=
dir=exp/nnet2_online/nnet_ms_b
has_fisher=true

. ./path.sh
. ./utils/parse_options.sh

if $use_gpu; then
  if ! cuda-compiled; then
    cat <<EOF && exit 1 
This script is intended to be used with GPUs but you have not compiled Kaldi with CUDA 
If you want to use GPUs (and have them), go to src/, and configure and make on a machine
where "nvcc" is installed.  Otherwise, call this script with --use-gpu false
EOF
  fi
  parallel_opts="-l gpu=1" 
  num_threads=1
  minibatch_size=512
  # the _a is in case I want to change the parameters.
else
  # Use 4 nnet jobs just like run_4d_gpu.sh so the results should be
  # almost the same, but this may be a little bit slow.
  num_threads=16
  minibatch_size=128
  parallel_opts="-pe smp $num_threads" 
fi


# Run the common stages of training, including training the iVector extractor
local/online/run_nnet2_common.sh --stage $stage || exit 1;

if [ $stage -le 6 ]; then
  #Although the nnet will be trained by high resolution data, we still have to perturbe the normal data to get the alignment
  # _sp stands for speed-perturbed
  utils/perturb_data_dir_speed.sh 0.9 data/train_nodup data/temp1
  utils/perturb_data_dir_speed.sh 1.0 data/train_nodup data/temp2
  utils/perturb_data_dir_speed.sh 1.1 data/train_nodup data/temp3
  utils/combine_data.sh data/train_nodup_sp data/temp1 data/temp2 data/temp3
  rm -r data/temp1 data/temp2 data/temp3

  mfccdir=mfcc_perturbed
  for x in train_nodup_sp; do
    steps/make_mfcc.sh --cmd "$train_cmd" --nj 50 \
      data/$x exp/make_mfcc/$x $mfccdir || exit 1;
    steps/compute_cmvn_stats.sh data/$x exp/make_mfcc/$x $mfccdir || exit 1;
  done
  utils/fix_data_dir.sh data/train_nodup_sp
fi

if [ $stage -le 7 ]; then
  #obtain the alignment of the perturbed data
  steps/align_fmllr.sh --nj 100 --cmd "$train_cmd" \
    data/train_nodup_sp data/lang exp/tri4 exp/tri4_ali_nodup_sp || exit 1
fi

if [ $stage -le 8 ]; then
  #Now perturb the high resolution daa
  utils/perturb_data_dir_speed.sh 0.9 data/train_hires_nodup data/temp1
  utils/perturb_data_dir_speed.sh 1.0 data/train_hires_nodup data/temp2
  utils/perturb_data_dir_speed.sh 1.1 data/train_hires_nodup data/temp3
  utils/combine_data.sh data/train_hires_nodup_sp data/temp1 data/temp2 data/temp3
  rm -r data/temp1 data/temp2 data/temp3

  mfccdir=mfcc_perturbed
  for x in train_hires_nodup_sp; do
    steps/make_mfcc.sh --cmd "$train_cmd" --nj 70 --mfcc-config conf/mfcc_hires.conf \
      data/$x exp/make_hires/$x $mfccdir || exit 1;
    steps/compute_cmvn_stats.sh data/$x exp/make_hires/$x $mfccdir || exit 1;
  done
  utils/fix_data_dir.sh data/train_hires_nodup_sp
fi

if [ $stage -le 9 ]; then
  # We extract iVectors on all the train_nodup data, which will be what we
  # train the system on.

  # having a larger number of speakers is helpful for generalization, and to
  # handle per-utterance decoding well (iVector starts at zero).
  steps/online/nnet2/copy_data_dir.sh --utts-per-spk-max 2 data/train_hires_nodup_sp data/train_hires_nodup_sp_max2

  steps/online/nnet2/extract_ivectors_online.sh --cmd "$train_cmd" --nj 30 \
    data/train_hires_nodup_sp_max2 exp/nnet2_online/extractor exp/nnet2_online/ivectors_train_hires_nodup_sp2 || exit 1;
fi

if [ $stage -le 10 ]; then
  steps/nnet2/train_multisplice_accel2.sh --stage $train_stage \
    --num-epochs 2 --num-jobs-initial 3 --num-jobs-final 16 \
    --num-hidden-layers 4 --splice-indexes "$splice_indexes" \
    --feat-type raw \
    --online-ivector-dir exp/nnet2_online/ivectors_train_hires_nodup_sp2 \
    --cmvn-opts "--norm-means=false --norm-vars=false" \
    --num-threads "$num_threads" \
    --minibatch-size "$minibatch_size" \
    --parallel-opts "$parallel_opts" \
    --io-opts "--max-jobs-run 12" \
    --add-layers-period 1 \
    --mix-up 4000 \
    --initial-effective-lrate 0.0017 --final-effective-lrate 0.00017 \
    --cmd "$decode_cmd" \
    --egs-dir "$common_egs_dir" \
    --pnorm-input-dim 2750 \
    --pnorm-output-dim 275 \
    data/train_hires_nodup_sp data/lang exp/tri4_ali_nodup_sp $dir  || exit 1;
fi

if [ $stage -le 11 ]; then
  for data in eval2000_hires train_hires_dev; do
    steps/online/nnet2/extract_ivectors_online.sh --cmd "$train_cmd" --nj 20 \
      data/${data} exp/nnet2_online/extractor exp/nnet2_online/ivectors_${data} || exit 1;
  done
fi

if [ $stage -le 12 ]; then
  # this does offline decoding that should give the same results as the real
  # online decoding (the one with --per-utt true)
  graph_dir=exp/tri4/graph_sw1_tg
  # use already-built graphs.
 # for data in eval2000_hires train_hires_dev; do
  for data in eval2000_hires ; do
    steps/nnet2/decode.sh --nj 30 --cmd "$decode_cmd" \
      --config conf/decode.config \
      --online-ivector-dir exp/nnet2_online/ivectors_${data} \
      $graph_dir data/${data} $dir/decode_${data}_sw1_tg || exit 1;
    if $has_fisher; then
      steps/lmrescore_const_arpa.sh --cmd "$decode_cmd" \
        data/lang_sw1_{tg,fsh_fg} data/${data} \
        $dir/decode_${data}_sw1_{tg,fsh_fg} || exit 1;
    fi
  done
fi

if [ $stage -le 13 ]; then
  # If this setup used PLP features, we'd have to give the option --feature-type plp
  # to the script below.
  steps/online/nnet2/prepare_online_decoding.sh --mfcc-config conf/mfcc_hires.conf \
      data/lang exp/nnet2_online/extractor "$dir" ${dir}_online || exit 1;
fi

if [ $stage -le 14 ]; then
  # do the actual online decoding with iVectors, carrying info forward from 
  # previous utterances of the same speaker.
  graph_dir=exp/tri4/graph_sw1_tg
  for data in eval2000_hires train_hires_dev; do
    steps/online/nnet2/decode.sh --config conf/decode.config \
      --cmd "$decode_cmd" --nj 30 \
      "$graph_dir" data/${data} \
      ${dir}_online/decode_${data}_sw1_tg || exit 1;
    if $has_fisher; then
      steps/lmrescore_const_arpa.sh --cmd "$decode_cmd" \
        data/lang_sw1_{tg,fsh_fg} data/${data} \
        ${dir}_online/decode_${data}_sw1_{tg,fsh_fg} || exit 1;
    fi
  done
fi

if [ $stage -le 15 ]; then
  # this version of the decoding treats each utterance separately
  # without carrying forward speaker information.
  graph_dir=exp/tri4/graph_sw1_tg
  for data in eval2000_hires train_hires_dev; do
    steps/online/nnet2/decode.sh --config conf/decode.config \
      --cmd "$decode_cmd" --nj 30 --per-utt true \
      "$graph_dir" data/${data} \
      ${dir}_online/decode_${data}_sw1_tg_per_utt || exit 1;
    if $has_fisher; then
      steps/lmrescore_const_arpa.sh --cmd "$decode_cmd" \
        data/lang_sw1_{tg,fsh_fg} data/${data} \
        ${dir}_online/decode_${data}_sw1_{tg,fsh_fg}_per_utt || exit 1;
    fi
  done
fi

exit 0;
