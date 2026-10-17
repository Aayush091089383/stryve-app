/// The PDF rendering surface used by the assignment viewer.
///
/// The viewer screen talks to a [PdfSurfaceHandle] - page count, current page,
/// zoom - and never to a PDF library directly. The shipped implementation is
/// pdfrx (PDFium), which renders from the bytes already in memory, so viewing a
/// PDF writes nothing to the device. Tests inject their own factory, which is
/// why the page can be widget-tested without a native PDF engine.
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

/// The page-level state and controls of a rendered PDF.
abstract class PdfSurfaceHandle extends ChangeNotifier {
  /// True once pages can be laid out (and the toolbar is safe to use).
  bool get isReady;

  /// True when the PDF could not be parsed/rendered at all.
  bool get hasFailed;

  int get pageCount;

  /// 1-based current page.
  int get currentPage;

  Future<void> goToPage(int pageNumber);

  Future<void> zoomIn();

  Future<void> zoomOut();
}

/// A PDF surface: how to build it, and how to drive it.
class PdfSurface {
  PdfSurface({required this.handle, required this.builder});

  final PdfSurfaceHandle handle;
  final PdfSurfaceBuilder builder;

  Widget build(BuildContext context, Uint8List bytes, String sourceName) =>
      builder(context, bytes, sourceName);
}

typedef PdfSurfaceBuilder = Widget Function(
  BuildContext context,
  Uint8List bytes,
  String sourceName,
);

/// Creates a surface. Injectable so widget tests never start the native engine.
typedef PdfSurfaceFactory = PdfSurface Function();

/// The surface the app ships: in-memory rendering through pdfrx/PDFium.
PdfSurface createPdfrxSurface() {
  final handle = PdfrxSurfaceHandle();
  return PdfSurface(
    handle: handle,
    builder: (context, bytes, sourceName) => PdfViewer.data(
      bytes,
      sourceName: sourceName,
      controller: handle.controller,
      params: PdfViewerParams(
        onViewerReady: (document, _) => handle.reportReady(document.pages.length),
        onDocumentLoadFinished: (_, succeeded) {
          if (!succeeded) handle.reportFailure();
        },
        onPageChanged: handle.reportPage,
      ),
    ),
  );
}

/// [PdfSurfaceHandle] backed by a pdfrx [PdfViewerController].
///
/// The controller only exposes `pageCount`/`pageNumber` once its viewer has a
/// loaded document, so this wrapper keeps its own copy and only forwards
/// commands that are safe at the current state.
class PdfrxSurfaceHandle extends PdfSurfaceHandle {
  final PdfViewerController controller = PdfViewerController();

  bool _failed = false;
  int _pageCount = 0;
  int _currentPage = 1;

  @override
  bool get isReady => !_failed && _pageCount > 0 && controller.isReady;

  @override
  bool get hasFailed => _failed;

  @override
  int get pageCount => _pageCount;

  @override
  int get currentPage => _currentPage;

  void reportReady(int pageCount) {
    _pageCount = pageCount;
    notifyListeners();
  }

  void reportFailure() {
    if (_failed) return;
    _failed = true;
    notifyListeners();
  }

  void reportPage(int? pageNumber) {
    if (pageNumber == null || pageNumber == _currentPage) return;
    _currentPage = pageNumber;
    notifyListeners();
  }

  @override
  Future<void> goToPage(int pageNumber) async {
    if (!controller.isReady) return;
    final target = pageNumber.clamp(1, _pageCount == 0 ? 1 : _pageCount);
    if (target == _currentPage) return;
    await controller.goToPage(pageNumber: target);
  }

  @override
  Future<void> zoomIn() async {
    if (!controller.isReady) return;
    await controller.zoomUp();
  }

  @override
  Future<void> zoomOut() async {
    if (!controller.isReady) return;
    await controller.zoomDown();
  }
}
