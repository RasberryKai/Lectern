import {Config} from '@remotion/cli/config';

Config.setEntryPoint('src/Root.tsx');
Config.setVideoImageFormat('jpeg');
Config.setJpegQuality(95);
Config.setCodec('h264');
Config.setCrf(16);
