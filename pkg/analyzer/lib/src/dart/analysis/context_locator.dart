// Copyright (c) 2018, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:collection';

import 'package:analyzer/context/context_root.dart' as old;
import 'package:analyzer/dart/analysis/analysis_context.dart';
import 'package:analyzer/dart/analysis/context_locator.dart';
import 'package:analyzer/file_system/file_system.dart';
import 'package:analyzer/file_system/physical_file_system.dart'
    show PhysicalResourceProvider;
import 'package:analyzer/src/context/builder.dart'
    show ContextBuilder, ContextBuilderOptions;
import 'package:analyzer/src/dart/analysis/driver.dart'
    show AnalysisDriver, AnalysisDriverScheduler;
import 'package:analyzer/src/dart/analysis/driver_based_analysis_context.dart';
import 'package:analyzer/src/dart/analysis/file_state.dart'
    show FileContentOverlay;
import 'package:analyzer/src/dart/sdk/sdk.dart' show FolderBasedDartSdk;
import 'package:analyzer/src/generated/sdk.dart' show DartSdkManager;
import 'package:analyzer/src/generated/source.dart' show ContentCache;
import 'package:front_end/src/base/performance_logger.dart' show PerformanceLog;
import 'package:front_end/src/byte_store/byte_store.dart' show MemoryByteStore;
import 'package:meta/meta.dart';

/**
 * An implementation of a context locator.
 */
class ContextLocatorImpl implements ContextLocator {
  /**
   * The name of the analysis options file.
   */
  static const String ANALYSIS_OPTIONS_NAME = 'analysis_options.yaml';

  /**
   * The old name of the analysis options file.
   */
  static const String OLD_ANALYSIS_OPTIONS_NAME = '.analysis_options';

  /**
   * The name of the packages folder.
   */
  static const String PACKAGES_DIR_NAME = 'packages';

  /**
   * The name of the packages file.
   */
  static const String PACKAGES_FILE_NAME = '.packages';

  /**
   * The resource provider used to access the file system.
   */
  final ResourceProvider resourceProvider;

  /**
   * Initialize a newly created context locator. If a [resourceProvider] is
   * supplied, it will be used to access the file system. Otherwise the default
   * resource provider will be used.
   */
  ContextLocatorImpl({ResourceProvider resourceProvider})
      : this.resourceProvider =
            resourceProvider ?? PhysicalResourceProvider.INSTANCE;

  /**
   * Return the path to the default location of the SDK.
   */
  String get _defaultSdkPath =>
      FolderBasedDartSdk.defaultSdkDirectory(resourceProvider).path;

  @override
  List<AnalysisContext> locateContexts(
      {@required List<String> includedPaths,
      List<String> excludedPaths: null,
      String packagesFile: null,
      String sdkPath: null}) {
    if (includedPaths == null || includedPaths.isEmpty) {
      throw new ArgumentError('There must be at least one included path');
    }
    List<AnalysisContext> contextList = <AnalysisContext>[];
    List<ContextRoot> roots =
        locateRoots(includedPaths, excludedPaths: excludedPaths);
    PerformanceLog performanceLog = new PerformanceLog(new StringBuffer());
    AnalysisDriverScheduler scheduler =
        new AnalysisDriverScheduler(performanceLog);
    DartSdkManager sdkManager =
        new DartSdkManager(sdkPath ?? _defaultSdkPath, true);
    scheduler.start();
    ContextBuilderOptions options = new ContextBuilderOptions();
    ContextBuilder builder = new ContextBuilder(
        resourceProvider, sdkManager, new ContentCache(),
        options: options);
    if (packagesFile != null) {
      options.defaultPackageFilePath = packagesFile;
    }
    builder.analysisDriverScheduler = scheduler;
    builder.byteStore = new MemoryByteStore();
    builder.fileContentOverlay = new FileContentOverlay();
    builder.performanceLog = performanceLog;
    for (ContextRoot root in roots) {
      old.ContextRoot contextRoot =
          new old.ContextRoot(root.root.path, root.excludedPaths);
      AnalysisDriver driver = builder.buildDriver(contextRoot);
      DriverBasedAnalysisContext context =
          new DriverBasedAnalysisContext(resourceProvider, driver);
      context.includedPaths = root.includedPaths;
      context.excludedPaths = root.excludedPaths;
      contextList.add(context);
    }
    return contextList;
  }

  /**
   * Return a list of the context roots that should be used to analyze the files
   * that are included by the list of [includedPaths] and not excluded by the
   * list of [excludedPaths].
   */
  @visibleForTesting
  List<ContextRoot> locateRoots(List<String> includedPaths,
      {List<String> excludedPaths}) {
    //
    // Compute the list of folders and files that are to be included.
    //
    List<Folder> includedFolders = <Folder>[];
    List<File> includedFiles = <File>[];
    _resourcesFromPaths(includedPaths, includedFolders, includedFiles);
    //
    // Compute the list of folders and files that are to be excluded.
    //
    List<Folder> excludedFolders = <Folder>[];
    List<File> excludedFiles = <File>[];
    _resourcesFromPaths(
        excludedPaths ?? const <String>[], excludedFolders, excludedFiles);
    //
    // Use the excluded folders and files to filter the included folders and
    // files.
    //
    includedFolders = includedFolders
        .where((Folder includedFolder) =>
            !_containedInAny(excludedFolders, includedFolder) &&
            !_containedInAny(includedFolders, includedFolder))
        .toList();
    includedFiles = includedFiles
        .where((File includedFile) =>
            !_containedInAny(excludedFolders, includedFile) &&
            !excludedFiles.contains(includedFile) &&
            !_containedInAny(includedFolders, includedFile))
        .toList();
    //
    // We now have a list of all of the files and folders that need to be
    // analyzed. For each, walk the directory structure and figure out where to
    // create context roots.
    //
    List<ContextRoot> roots = <ContextRoot>[];
    for (Folder folder in includedFolders) {
      _createContextRoots(roots, folder, excludedFolders, null);
    }
    for (File file in includedFiles) {
      Folder parent = file.parent;
      ContextRoot root = new ContextRoot(file);
      root.packagesFile = _findPackagesFile(parent);
      root.optionsFile = _findOptionsFile(parent);
      root.included.add(file);
      roots.add(root);
    }

    return roots;
  }

  /**
   * Return `true` if the given [resource] is contained in one or more of the
   * given [folders].
   */
  bool _containedInAny(Iterable<Folder> folders, Resource resource) =>
      folders.any((Folder folder) => folder.contains(resource.path));

  void _createContextRoots(List<ContextRoot> roots, Folder folder,
      List<Folder> excludedFolders, ContextRoot containingRoot) {
    //
    // Create a context root for the given [folder] is appropriate.
    //
    if (containingRoot == null) {
      ContextRoot root = new ContextRoot(folder);
      root.packagesFile = _findPackagesFile(folder);
      root.optionsFile = _findOptionsFile(folder);
      root.included.add(folder);
      roots.add(root);
      containingRoot = root;
    } else {
      File packagesFile = _getPackagesFile(folder);
      File optionsFile = _getOptionsFile(folder);
      if (packagesFile != null || optionsFile != null) {
        ContextRoot root = new ContextRoot(folder);
        root.packagesFile = packagesFile ?? containingRoot.packagesFile;
        root.optionsFile = optionsFile ?? containingRoot.optionsFile;
        root.included.add(folder);
        containingRoot.excluded.add(folder);
        roots.add(root);
        containingRoot = root;
      }
    }
    //
    // Check each of the subdirectories to see whether a context root needs to
    // be added for it.
    //
    try {
      for (Resource child in folder.getChildren()) {
        if (child is Folder) {
          if (excludedFolders.contains(folder) ||
              folder.shortName.startsWith('.') ||
              folder.shortName == PACKAGES_DIR_NAME) {
            containingRoot.excluded.add(folder);
          } else {
            _createContextRoots(roots, child, excludedFolders, containingRoot);
          }
        }
      }
    } on FileSystemException {
      // The directory either doesn't exist or cannot be read. Either way, there
      // are no subdirectories that need to be added.
    }
  }

  /**
   * Return the analysis options file to be used to analyze files in the given
   * [folder], or `null` if there is no analysis options file in the given
   * folder or any parent folder.
   */
  File _findOptionsFile(Folder folder) {
    while (folder != null) {
      File packagesFile = _getOptionsFile(folder);
      if (packagesFile != null) {
        return packagesFile;
      }
      folder = folder.parent;
    }
    return null;
  }

  /**
   * Return the packages file to be used to analyze files in the given [folder],
   * or `null` if there is no packages file in the given folder or any parent
   * folder.
   */
  File _findPackagesFile(Folder folder) {
    while (folder != null) {
      File packagesFile = _getPackagesFile(folder);
      if (packagesFile != null) {
        return packagesFile;
      }
      folder = folder.parent;
    }
    return null;
  }

  /**
   * If the given [directory] contains a file with the given [name], then return
   * the file. Otherwise, return `null`.
   */
  File _getFile(Folder directory, String name) {
    Resource resource = directory.getChild(name);
    if (resource is File && resource.exists) {
      return resource;
    }
    return null;
  }

  /**
   * Return the analysis options file in the given [folder], or `null` if the
   * folder does not contain an analysis options file.
   */
  File _getOptionsFile(Folder folder) =>
      _getFile(folder, ANALYSIS_OPTIONS_NAME) ??
      _getFile(folder, OLD_ANALYSIS_OPTIONS_NAME);

  /**
   * Return the packages file in the given [folder], or `null` if the folder
   * does not contain a packages file.
   */
  File _getPackagesFile(Folder folder) => _getFile(folder, PACKAGES_FILE_NAME);

  /**
   * Add to the given lists of [folders] and [files] all of the resources in the
   * given list of [paths] that exist and are not contained within one of the
   * folders.
   */
  void _resourcesFromPaths(
      List<String> paths, List<Folder> folders, List<File> files) {
    for (String path in _uniqueSortedPaths(paths)) {
      Resource resource = resourceProvider.getResource(path);
      if (resource.exists && !_containedInAny(folders, resource)) {
        if (resource is Folder) {
          folders.add(resource);
        } else if (resource is File) {
          files.add(resource);
        } else {
          // Internal error: unhandled kind of resource.
        }
      }
    }
  }

  /**
   * Return a list of paths that contains all of the unique elements from the
   * given list of [paths], sorted such that shorter paths are first.
   */
  List<String> _uniqueSortedPaths(List<String> paths) {
    Set<String> uniquePaths = new HashSet<String>.from(paths);
    List<String> sortedPaths = uniquePaths.toList();
    sortedPaths.sort((a, b) => a.length - b.length);
    return sortedPaths;
  }
}

@visibleForTesting
class ContextRoot {
  final Resource root;
  final List<Resource> included = <Resource>[];
  final List<Resource> excluded = <Resource>[];
  File packagesFile;
  File optionsFile;

  ContextRoot(this.root);

  List<String> get excludedPaths =>
      excluded.map((Resource folder) => folder.path).toList();

  @override
  int get hashCode => root.path.hashCode;

  List<String> get includedPaths =>
      included.map((Resource folder) => folder.path).toList();

  @override
  bool operator ==(Object other) {
    return other is ContextRoot && root.path == other.root.path;
  }
}