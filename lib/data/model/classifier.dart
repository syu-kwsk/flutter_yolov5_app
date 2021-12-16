import 'dart:math';
import 'dart:ui';

import 'package:image/image.dart' as image_lib;
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:tflite_flutter_helper/tflite_flutter_helper.dart';

import 'package:flutter_yolov5_app/utils/logger.dart';
import 'package:flutter_yolov5_app/data/entity/recognition.dart';

class Classifier {
  Classifier({
    Interpreter? interpreter,
  }) {
    loadModel(interpreter);
  }
  late Interpreter? _interpreter;
  Interpreter? get interpreter => _interpreter;

  static const String modelFileName = 'coco128.tflite';

  /// image size into interpreter
  static const int inputSize = 640;

  ImageProcessor? imageProcessor;
  late List<List<int>> _outputShapes;
  late List<TfLiteType> _outputTypes;

  static const int clsNum = 80;
  static const double objConfTh = 0.80;
  static const double clsConfTh = 0.80;

  /// load interpreter
  Future<void> loadModel(Interpreter? interpreter) async {
    try {
      _interpreter = interpreter ??
          await Interpreter.fromAsset(
            modelFileName,
            options: InterpreterOptions()..threads = 4,
          );
      final outputTensors = _interpreter!.getOutputTensors();
      _outputShapes = [];
      _outputTypes = [];
      for (final tensor in outputTensors) {
        _outputShapes.add(tensor.shape);
        _outputTypes.add(tensor.type);
      }
    } on Exception catch (e) {
      logger.warning(e.toString());
    }
  }

  /// image pre process
  TensorImage getProcessedImage(TensorImage inputImage) {
    final padSize = max(inputImage.height, inputImage.width);

    imageProcessor ??= ImageProcessorBuilder()
        .add(
      ResizeWithCropOrPadOp(
        padSize,
        padSize,
      ),
    )
        .add(
      ResizeOp(
        inputSize,
        inputSize,
        ResizeMethod.BILINEAR,
      ),
    )
        .build();
    return imageProcessor!.process(inputImage);
  }

  List<Recognition> predict(image_lib.Image image) {
    if (_interpreter == null) {
      return [];
    }

    var inputImage = TensorImage.fromImage(image);
    inputImage = getProcessedImage(inputImage);

    ///  normalize from zero to one
    List<double> normalizedInputImage = [];
    for (var pixel in inputImage.tensorBuffer.getDoubleList()) {
      normalizedInputImage.add(pixel / 255.0);
    }
    var normalizedTensorBuffer = TensorBuffer.createDynamic(TfLiteType.float32);
    normalizedTensorBuffer.loadList(normalizedInputImage, shape: [inputSize, inputSize, 3]);

    final inputs = [normalizedTensorBuffer.buffer];

    /// tensor for results of inference
    final outputLocations = TensorBufferFloat(_outputShapes[0]);
    final outputs = {
      0: outputLocations.buffer,
    };

    _interpreter!.runForMultipleInputs(inputs, outputs);

    /// make recognition
    final recognitions = <Recognition>[];
    List<double> results = outputLocations.getDoubleList();
    for (var i = 0; i < results.length; i += (5 + clsNum)) {
      // check obj conf
      if (results[i + 4] < objConfTh) continue;

      /// check cls conf
      // double maxClsConf = results[i + 5];
      double maxClsConf = results.sublist(i + 5, i + 5 + clsNum - 1).reduce(max);
      if (maxClsConf < clsConfTh) continue;

      /// add detects
      // int cls = 0;
      int cls = results.sublist(i + 5, i + 5 + clsNum - 1).indexOf(maxClsConf) % clsNum;
      Rect outputRect = Rect.fromCenter(
        center: Offset(
          results[i] * inputSize,
          results[i + 1] * inputSize,
        ),
        width: results[i + 2] * inputSize,
        height: results[i + 3] * inputSize,
      );
      Rect transformRect = imageProcessor!.inverseTransformRect(outputRect, image.height, image.width);

      recognitions.add(
          Recognition(i, cls, maxClsConf, transformRect)
      );
    }
    return recognitions;
  }
}
