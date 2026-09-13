import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:two_dimensional_scrollables/two_dimensional_scrollables.dart';

import 'core/models/listview_config_model.dart';
import 'core/models/table_column_config.dart';
import 'data_table_view.dart';
import 'fix_aware_horizontal_scrollbar.dart';
import 'fix_aware_vertical_scrollbar.dart';
import 'listview_empty_data.dart';
import 'table_cell.dart';

class TableView2 extends StatefulWidget {
  const TableView2({
    super.key,
    this.empty,
    this.emptyMessage,
    required this.rows,
    this.onSelectAll,
    required this.dataRowHeight,
    required this.headingRowHeight,
    required this.listViewConfig,
    required this.onConfigUpdated,
    this.onFilter,
    this.sortColumnIndex,
    this.sortAscending,
    this.fixedRowCount = 1,
    this.tableHeaderColor = Colors.blueAccent,
    this.isUseMaxWidth = false,
    this.hoveredIndexNotifier,
    this.sortIconColor = Colors.white,
    this.enableColumnResize = true,
    this.resizeHandleWidth = 14.0,
    this.enableRowResize = true,
    this.resizeHandleHeight = 8.0,
    this.minDataRowHeight = 44.0,
    this.maxDataRowHeight = 400.0,
    this.filterIcon,
    this.widgetTextHeader,
    this.headingTextStyle,
    this.rowHoverColor = const Color(0x0A000000),
    this.rowSelectedColor = const Color(0x1A448AFF),
  });
  final Widget? empty;
  final String? emptyMessage;
  final List<DataRowTableView> rows;
  final ValueSetter<bool?>? onSelectAll;
  final double dataRowHeight;
  final double headingRowHeight;
  final ListViewConfigModel listViewConfig;
  final Function(TableColumnConfig) onConfigUpdated;
  final void Function(TableColumnConfig)? onFilter;
  final int? sortColumnIndex;
  final bool? sortAscending;
  final int fixedRowCount;
  final Color tableHeaderColor;
  final ValueNotifier<int>? hoveredIndexNotifier;
  final bool isUseMaxWidth;
  final Color sortIconColor;
  final bool enableColumnResize;
  final double resizeHandleWidth;
  final TextStyle? headingTextStyle;
  final Widget Function(BuildContext context, TableColumnConfig column)?
  widgetTextHeader;
  final Widget Function(bool isActiveFilter)? filterIcon;

  /// Drag the bottom border of data rows to change row height (session only).
  final bool enableRowResize;
  final double resizeHandleHeight;
  final double minDataRowHeight;
  final double maxDataRowHeight;
  final Color rowHoverColor;
  final Color rowSelectedColor;

  @override
  State<TableView2> createState() => _TableView2State();
  static CheckboxThemeData checkboxTheme(BuildContext context) =>
      Theme.of(context).checkboxTheme.copyWith(
        side: WidgetStateBorderSide.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return const BorderSide(color: Colors.blueAccent, width: .05);
          }
          if (states.contains(WidgetState.focused)) {
            return const BorderSide(color: Colors.white, width: 1);
          }
          return const BorderSide(color: Colors.grey, width: 1);
        }),
        fillColor: WidgetStateProperty.resolveWith<Color>((states) {
          if (states.contains(WidgetState.selected)) {
            return Colors.blueAccent; // Bright blue
          }
          return Colors.transparent; // No fill when unchecked
        }),
      );
  static CheckboxThemeData headingCheckboxThemeTwoDimensional(
    BuildContext context,
    bool isSelectedAll,
  ) => Theme.of(context).checkboxTheme.copyWith(
    side: WidgetStateBorderSide.resolveWith((states) {
      if (states.contains(WidgetState.selected)) {
        return BorderSide(
          color: isSelectedAll ? Colors.transparent : Colors.white,
          width: 0.5,
        );
      }
      if (states.contains(WidgetState.focused)) {
        return const BorderSide(color: Colors.white, width: 0.5);
      }
      return const BorderSide(color: Colors.white, width: 0.5);
    }),
    fillColor: WidgetStateProperty.resolveWith<Color>((states) {
      if (states.contains(WidgetState.selected)) {
        return isSelectedAll ? Colors.blueAccent : Colors.transparent;
      }
      return Colors.transparent;
    }),
  );

  static Color getSortIconColor(
    int sortColumnIndex,
    int currentIndex,
    bool sortAscending,
    Color sortIconColor,
  ) {
    if (sortColumnIndex == currentIndex && sortAscending) {
      return Colors.orange;
    } else if (sortColumnIndex == currentIndex && !sortAscending) {
      return Colors.orange;
    } else {
      return sortIconColor;
    }
  }
}

class _TableView2State extends State<TableView2> {
  late final ScrollController _horizontalScrollController;
  late final ScrollController _verticalScrollController;
  late final ValueNotifier<ScrollMetrics?> _horizontalMetricsNotifier;
  late final ValueNotifier<ScrollMetrics?> _verticalMetricsNotifier;
  final _RowHighlightController _rowHighlight = _RowHighlightController();
  String? _resizingColumnKey;
  double _resizeStartWidth = 0;
  bool _isResizingRowHeight = false;
  int? _resizingDataRowIndex;
  double? _lastHoverLocalDy;

  /// Session-only per-row heights, keyed by data row index.
  final Map<int, double> _localDataRowHeights = {};

  /// Latest table viewport width (from LayoutBuilder).
  double _viewportWidth = 0;

  /// Keep at least this much width for horizontally scrollable (unpinned) area.
  static const double _minHorizontalScrollableArea = 200;

  double _effectiveDataRowHeightAt(int dataRowIndex) {
    return _localDataRowHeights[dataRowIndex] ?? widget.dataRowHeight;
  }

  @override
  void initState() {
    super.initState();
    _horizontalScrollController = ScrollController();
    _verticalScrollController = ScrollController();
    _horizontalMetricsNotifier = ValueNotifier<ScrollMetrics?>(null);
    _verticalMetricsNotifier = ValueNotifier<ScrollMetrics?>(null);
    _verticalScrollController.addListener(_recomputeHoveredRowFromPointer);
    _rowHighlight.syncSelected(_selectedRowIndices());
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncInitialMetrics());
  }

  @override
  void didUpdateWidget(covariant TableView2 oldWidget) {
    super.didUpdateWidget(oldWidget);
    _rowHighlight.syncSelected(_selectedRowIndices());
    if (_rowHighlight.hovered >= widget.rows.length) {
      _setHoveredRow(-1);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncInitialMetrics());
  }

  void _syncInitialMetrics() {
    if (!mounted) return;
    if (_horizontalScrollController.hasClients) {
      _horizontalMetricsNotifier.value = _horizontalScrollController.position;
    }
    if (_verticalScrollController.hasClients) {
      _verticalMetricsNotifier.value = _verticalScrollController.position;
    }
  }

  void _applyScrollMetricsForScrollbar(ScrollMetrics metrics) {
    void apply() {
      if (!mounted) return;
      if (metrics.axis == Axis.horizontal) {
        _horizontalMetricsNotifier.value = metrics;
      } else if (metrics.axis == Axis.vertical) {
        _verticalMetricsNotifier.value = metrics;
      }
    }

    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) => apply());
    } else {
      apply();
    }
  }

  @override
  void dispose() {
    _verticalScrollController.removeListener(_recomputeHoveredRowFromPointer);
    _horizontalScrollController.dispose();
    _verticalScrollController.dispose();
    _horizontalMetricsNotifier.dispose();
    _verticalMetricsNotifier.dispose();
    _rowHighlight.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.rows.isEmpty) {
      return _buildDefaultEmptyState();
    }
    return _buildTableView();
  }

  Widget _buildDefaultEmptyState() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.start,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: _buildTableView()),
        Expanded(
          child:
              widget.empty ??
              ListviewEmptyData(
                alignment: Alignment.topCenter,
                size: const Size(double.infinity, double.infinity),
                message: widget.emptyMessage ?? 'Không có dữ liệu',
              ),
        ),
      ],
    );
  }

  Widget _buildTableView() {
    return LayoutBuilder(
      builder: (context, constraints) {
        _viewportWidth = constraints.maxWidth;
        final totalColumns =
            _getTotalColumnsCount() +
            (widget.listViewConfig.isHaveCheckBox ? 1 : 0);
        final rowCount = widget.fixedRowCount + widget.rows.length;
        final headerHeight = widget.headingRowHeight * widget.fixedRowCount;
        final pinnedWidth = _pinnedColumnsWidth();
        final horizontalScrollbarLeft = math.min(
          pinnedWidth,
          math.max(0.0, _viewportWidth - 48),
        );
        final table = Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: MouseRegion(
            opaque: false,
            onHover: (event) {
              _lastHoverLocalDy = event.localPosition.dy;
              _setHoveredRow(_dataRowIndexFromLocalDy(event.localPosition.dy));
            },
            onExit: (_) {
              _lastHoverLocalDy = null;
              _setHoveredRow(-1);
            },
            child: NotificationListener<ScrollNotification>(
              onNotification: (notification) {
                _applyScrollMetricsForScrollbar(notification.metrics);
                return false;
              },
              child: ScrollConfiguration(
                behavior: ScrollConfiguration.of(context).copyWith(
                  scrollbars: false,
                  dragDevices: {
                    PointerDeviceKind.touch,
                    PointerDeviceKind.mouse,
                    PointerDeviceKind.trackpad,
                  },
                ),
                child: TableView.builder(
                  horizontalDetails: ScrollableDetails.horizontal(
                    controller: _horizontalScrollController,
                  ).copyWith(physics: const ClampingScrollPhysics()),
                  verticalDetails: ScrollableDetails.vertical(
                    controller: _verticalScrollController,
                  ).copyWith(physics: const ClampingScrollPhysics()),
                  rowCount: rowCount,
                  columnCount: totalColumns,
                  pinnedRowCount: widget.fixedRowCount,
                  cellBuilder: (context, vicinity) =>
                      _buildCell(context, vicinity),
                  pinnedColumnCount: widget.listViewConfig.fixedLeftColumns,
                  columnBuilder: (int index) => TableSpan(
                    extent: FixedTableSpanExtent(_getColumnWidth(index)),
                    foregroundDecoration: TableSpanDecoration(
                      border: TableSpanBorder(
                        leading: index == 0
                            ? const BorderSide(color: Colors.grey, width: 0.4)
                            : BorderSide.none,
                        trailing: const BorderSide(
                          color: Colors.grey,
                          width: 0.4,
                        ),
                      ),
                    ),
                  ),
                  rowBuilder: (int index) => TableSpan(
                    extent: FixedTableSpanExtent(
                      index < widget.fixedRowCount
                          ? widget.headingRowHeight
                          : _effectiveDataRowHeightAt(
                              index - widget.fixedRowCount,
                            ),
                    ),
                    foregroundDecoration: TableSpanDecoration(
                      border: TableSpanBorder(
                        leading: index == 0
                            ? const BorderSide(color: Colors.grey, width: 0.4)
                            : BorderSide.none,
                        trailing: const BorderSide(
                          color: Colors.grey,
                          width: 0.4,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        if (widget.rows.isEmpty) {
          return table;
        }
        return Stack(
          children: [
            table,
            Positioned(
              right: 0,
              top: headerHeight,
              bottom: 16,
              width: 12,
              child: FixedAwareVerticalScrollbar(
                controller: _verticalScrollController,
                metricsListenable: _verticalMetricsNotifier,
              ),
            ),
            Positioned(
              left: horizontalScrollbarLeft,
              right: 0,
              bottom: 0,
              height: 16,
              child: FixedAwareHorizontalScrollbar(
                controller: _horizontalScrollController,
                metricsListenable: _horizontalMetricsNotifier,
              ),
            ),
          ],
        );
      },
    );
  }

  TableViewCell _buildCell(BuildContext context, TableVicinity vicinity) {
    // Handle checkbox column
    if (widget.listViewConfig.isHaveCheckBox && vicinity.column == 0) {
      return _buildCheckboxCell(context, vicinity);
    }

    final adjustedColumnIndex = widget.listViewConfig.isHaveCheckBox
        ? vicinity.column - 1
        : vicinity.column;
    if (adjustedColumnIndex >= _columnList.length) {
      return const TableViewCell(child: ColoredBox(color: Colors.white));
    }

    final columnConfig = _columnList[adjustedColumnIndex];
    final bool isAlignCenter = columnConfig.isCenter;

    if (vicinity.row == 0) {
      final groupColumn = _getGroupColumn(adjustedColumnIndex);

      if (groupColumn != null) {
        final adjustedStart =
            groupColumn.range!.start +
            (widget.listViewConfig.isHaveCheckBox ? 1 : 0);

        return TableViewCell(
          columnMergeStart: adjustedStart,
          columnMergeSpan: groupColumn.range!.length,
          child: _headerCell(
            groupColumn.range!.groupTitle,
            context: context,
            columnConfig: groupColumn,
            index: vicinity.column,
            sortIconColor: widget.sortIconColor,
          ),
        );
      } else {
        // single Column
        return TableViewCell(
          rowMergeStart: 0,
          rowMergeSpan: widget.fixedRowCount,
          child: _headerCell(
            columnConfig.title,
            context: context,
            columnConfig: columnConfig,
            index: vicinity.column,
            sortIconColor: widget.sortIconColor,
          ),
        );
      }
    }
    TableViewCell cell = const TableViewCell(
      child: ColoredBox(color: Colors.white),
    );
    final int dataRow = vicinity.row - widget.fixedRowCount;
    if (dataRow >= 0 && dataRow < widget.rows.length) {
      final row = widget.rows[dataRow];
      final cellIndex = _cellIndexForVisibleColumn(adjustedColumnIndex);
      final dataChild = (cellIndex >= 0 && cellIndex < row.cells.length)
          ? TableCellWrapper(
              isCenter: isAlignCenter,
              child: row.cells[cellIndex],
            )
          : const SizedBox.shrink();
      cell = TableViewCell(
        child: InkWell(
          hoverColor: Colors.transparent,
          splashColor: Colors.transparent,
          highlightColor: Colors.transparent,
          focusColor: Colors.transparent,
          onTap: () => row.onTap?.call(),
          onSecondaryTapDown: (details) =>
              row.onSecondaryTapDown?.call(details),
          onDoubleTap: row.onDoubleTap,
          onLongPress: () => row.onLongPress?.call(),
          child: _wrapRowHighlight(
            dataRowIndex: dataRow,
            idleColor: Colors.transparent,
            child: Container(
              alignment: isAlignCenter
                  ? Alignment.center
                  : Alignment.centerLeft,
              child: _wrapDataCellWithRowResizeHandle(
                dataRowIndex: dataRow,
                child: dataChild,
              ),
            ),
          ),
        ),
      );
    }
    // HEADER ROW 2 (sub-headers)
    if (vicinity.row == 1) {
      final isGrouped = _isGroupedColumn(adjustedColumnIndex);

      if (isGrouped) {
        // Đây là sub-header của grouped column
        return TableViewCell(
          child: _headerCell(
            columnConfig.title,
            context: context,
            columnConfig: columnConfig,
            index: vicinity.column,
            sortIconColor: widget.sortIconColor,
          ),
        );
      } else {
        return cell;
      }
    }
    // Fallback
    return cell;
  }

  TableViewCell _buildCheckboxCell(
    BuildContext context,
    TableVicinity vicinity,
  ) {
    if (vicinity.row == 0) {
      return _buildHeaderCheckboxCell(context);
    }

    final int dataRow = vicinity.row - widget.fixedRowCount;
    if (dataRow >= 0 && dataRow < widget.rows.length) {
      return _buildDataCheckboxCell(context, widget.rows[dataRow], dataRow);
    }

    return const TableViewCell(child: ColoredBox(color: Colors.white));
  }

  TableViewCell _buildHeaderCheckboxCell(BuildContext context) {
    final allSelected = _areAllSelected();

    return TableViewCell(
      rowMergeStart: 0,
      rowMergeSpan: widget.fixedRowCount,
      child: Container(
        color: widget.tableHeaderColor,
        alignment: Alignment.center,
        padding: const EdgeInsets.all(8),
        child: CheckboxTheme(
          data: TableView2.headingCheckboxThemeTwoDimensional(
            context,
            allSelected ?? false,
          ),
          child: Checkbox(
            value: allSelected,
            tristate: true,
            onChanged: (value) {
              final checked = value ?? false;
              if (checked) {
                _rowHighlight.selectAll(widget.rows.length);
              } else {
                _rowHighlight.clearSelected();
              }
              widget.onSelectAll?.call(checked);
            },
          ),
        ),
      ),
    );
  }

  TableViewCell _buildDataCheckboxCell(
    BuildContext context,
    DataRowTableView row,
    int dataRowIndex,
  ) {
    return TableViewCell(
      child: _wrapDataCellWithRowResizeHandle(
        dataRowIndex: dataRowIndex,
        child: _wrapRowHighlight(
          dataRowIndex: dataRowIndex,
          idleColor: Colors.white,
          child: Container(
            alignment: Alignment.center,
            padding: const EdgeInsets.all(8),
            child: CheckboxTheme(
              data: row.enableCheckbox
                  ? TableView2.checkboxTheme(context)
                  : TableView2.checkboxTheme(context).copyWith(
                      fillColor: WidgetStateProperty.resolveWith<Color>((
                        states,
                      ) {
                        if (states.contains(WidgetState.selected)) {
                          return Colors.grey;
                        }
                        return Colors.transparent;
                      }),
                      checkColor: const WidgetStatePropertyAll(Colors.white),
                      side: WidgetStateBorderSide.resolveWith((states) {
                        return const BorderSide(color: Colors.grey, width: 1);
                      }),
                    ),
              child: Checkbox(
                value: row.enableCheckbox ? row.isChecked : true,
                onChanged: row.enableCheckbox
                    ? (value) {
                        final checked = value ?? false;
                        _rowHighlight.setSelected(dataRowIndex, checked);
                        row.onSelectChanged?.call(checked);
                      }
                    : null,
              ),
            ),
          ),
        ),
      ),
    );
  }

  bool? _areAllSelected() {
    if (widget.rows.isEmpty) return false;

    final selectedCount = widget.rows.where((item) => item.isChecked).length;
    if (selectedCount == 0) return false;
    if (selectedCount == widget.rows.length) return true;
    return null; // Indeterminate state
  }

  Set<int> _selectedRowIndices() {
    final selected = <int>{};
    for (var i = 0; i < widget.rows.length; i++) {
      if (widget.rows[i].selected) selected.add(i);
    }
    return selected;
  }

  void _setHoveredRow(int index) {
    final clamped = (index >= 0 && index < widget.rows.length) ? index : -1;
    final previous = _rowHighlight.hovered;
    if (previous == clamped) return;
    _rowHighlight.setHovered(clamped);
    widget.hoveredIndexNotifier?.value = clamped;
    if (previous >= 0 && previous < widget.rows.length) {
      widget.rows[previous].onHover?.call(false);
    }
    if (clamped >= 0) {
      widget.rows[clamped].onHover?.call(true);
    }
  }

  void _recomputeHoveredRowFromPointer() {
    final dy = _lastHoverLocalDy;
    if (dy == null) return;
    _setHoveredRow(_dataRowIndexFromLocalDy(dy));
  }

  int _dataRowIndexFromLocalDy(double localDy) {
    final headerHeight = widget.headingRowHeight * widget.fixedRowCount;
    if (localDy < headerHeight) return -1;
    final scrollOffset = _verticalScrollController.hasClients
        ? _verticalScrollController.offset
        : 0.0;
    var y = localDy - headerHeight + scrollOffset;
    if (y < 0) return -1;
    if (_localDataRowHeights.isEmpty) {
      final index = y ~/ widget.dataRowHeight;
      if (index < 0 || index >= widget.rows.length) return -1;
      return index;
    }
    for (var i = 0; i < widget.rows.length; i++) {
      final height = _effectiveDataRowHeightAt(i);
      if (y < height) return i;
      y -= height;
    }
    return -1;
  }

  Widget _wrapRowHighlight({
    required int dataRowIndex,
    required Color idleColor,
    required Widget child,
  }) {
    return _RowHighlightBackground(
      controller: _rowHighlight,
      rowIndex: dataRowIndex,
      idleColor: idleColor,
      hoverColor: widget.rowHoverColor,
      selectedColor: widget.rowSelectedColor,
      onEnter: () => _setHoveredRow(dataRowIndex),
      child: child,
    );
  }

  /// Drag the bottom border of a data row to change that row's height only.
  Widget _wrapDataCellWithRowResizeHandle({
    required int dataRowIndex,
    required Widget child,
  }) {
    if (!widget.enableRowResize) return child;
    return Stack(
      fit: StackFit.expand,
      clipBehavior: Clip.none,
      children: [
        // Fill the full cell so content stays vertically centered.
        Positioned.fill(child: child),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          height: widget.resizeHandleHeight,
          child: MouseRegion(
            cursor: SystemMouseCursors.resizeRow,
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onVerticalDragStart: (_) => _onDataRowResizeStart(dataRowIndex),
              onVerticalDragUpdate: (details) =>
                  _onDataRowResizeUpdate(dataRowIndex, details),
              onVerticalDragEnd: (_) => _onDataRowResizeEnd(),
              child: const ColoredBox(color: Colors.transparent),
            ),
          ),
        ),
      ],
    );
  }

  void _onDataRowResizeStart(int dataRowIndex) {
    _isResizingRowHeight = true;
    _resizingDataRowIndex = dataRowIndex;
  }

  void _onDataRowResizeUpdate(int dataRowIndex, DragUpdateDetails details) {
    if (!_isResizingRowHeight || _resizingDataRowIndex != dataRowIndex) return;
    final currentHeight = _effectiveDataRowHeightAt(dataRowIndex);
    final targetHeight = (currentHeight + details.delta.dy).clamp(
      widget.minDataRowHeight,
      widget.maxDataRowHeight,
    );
    if (_localDataRowHeights[dataRowIndex] == targetHeight) return;
    setState(() {
      _localDataRowHeights[dataRowIndex] = targetHeight;
    });
  }

  void _onDataRowResizeEnd() {
    if (!_isResizingRowHeight) return;
    _isResizingRowHeight = false;
    _resizingDataRowIndex = null;
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncInitialMetrics());
  }

  Widget _headerCell(
    String text, {
    required int index,
    required BuildContext context,
    required TableColumnConfig columnConfig,
    required Color sortIconColor,
  }) {
    final shouldCenter = columnConfig.isCenter;
    final isFilter = columnConfig.isFilter;
    final canResize =
        widget.enableColumnResize &&
        columnConfig.range == null &&
        columnConfig.maxWidth > columnConfig.minWidth;
    // Stack fills the whole cell so the resize handle sits on the real
    // column border — not inset by content padding.
    return Stack(
      fit: StackFit.expand,
      clipBehavior: Clip.none,
      children: [
        ColoredBox(
          color: widget.tableHeaderColor,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
            child: Row(
              mainAxisAlignment: isFilter
                  ? MainAxisAlignment.spaceBetween
                  : shouldCenter
                  ? MainAxisAlignment.center
                  : MainAxisAlignment.start,
              children: [
                Expanded(
                  child:
                      widget.widgetTextHeader?.call(context, columnConfig) ??
                      Text(
                        text,
                        style:
                            widget.headingTextStyle ??
                            const TextStyle(color: Colors.white),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        textAlign: shouldCenter
                            ? TextAlign.center
                            : TextAlign.left,
                      ),
                ),
                if (isFilter)
                  InkWell(
                    onTap: () => widget.onFilter?.call(columnConfig),
                    child:
                        widget.filterIcon?.call(columnConfig.isActiveFilter) ??
                        SvgPicture.asset(
                          'assets/actions/ico_filter.svg',
                          package: 'tableview2',
                          width: 14,
                          height: 14,
                        ),
                  ),
              ],
            ),
          ),
        ),
        if (canResize)
          Positioned(
            top: 0,
            bottom: 0,
            right: -(widget.resizeHandleWidth / 2),
            width: widget.resizeHandleWidth,
            child: MouseRegion(
              cursor: SystemMouseCursors.resizeColumn,
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onHorizontalDragStart: (_) =>
                    _onColumnResizeStart(columnConfig),
                onHorizontalDragUpdate: (details) =>
                    _onColumnResizeUpdate(columnConfig, details),
                onHorizontalDragEnd: (_) => _onColumnResizeEnd(),
                child: const ColoredBox(color: Colors.transparent),
              ),
            ),
          ),
      ],
    );
  }

  void _onColumnResizeStart(TableColumnConfig columnConfig) {
    _resizingColumnKey = columnConfig.key;
    _resizeStartWidth = columnConfig.width;
  }

  void _onColumnResizeUpdate(
    TableColumnConfig columnConfig,
    DragUpdateDetails details,
  ) {
    final currentColumn = _columnList
        .where((col) => col.key == columnConfig.key)
        .firstOrNull;
    final currentWidth = currentColumn?.width ?? _resizeStartWidth;
    var targetWidth = (currentWidth + details.delta.dx).clamp(
      columnConfig.minWidth,
      columnConfig.maxWidth,
    );

    // Pinned columns must leave room so horizontal scroll still works.
    final tableColumnIndex = _tableColumnIndexForKey(columnConfig.key);
    final pinnedCount = widget.listViewConfig.fixedLeftColumns;
    if (tableColumnIndex != null &&
        tableColumnIndex < pinnedCount &&
        _viewportWidth > 0) {
      var otherPinned = 0.0;
      for (var i = 0; i < pinnedCount; i++) {
        if (i == tableColumnIndex) continue;
        otherPinned += _rawColumnWidth(i);
      }
      final maxAllowed =
          (_viewportWidth - _minHorizontalScrollableArea - otherPinned).clamp(
            columnConfig.minWidth,
            columnConfig.maxWidth,
          );
      targetWidth = targetWidth.clamp(columnConfig.minWidth, maxAllowed);
    }

    final updatedConfig = columnConfig.copyWith(width: targetWidth);
    widget.onConfigUpdated(updatedConfig);
  }

  void _onColumnResizeEnd() {
    if (_resizingColumnKey == null) return;
    _resizingColumnKey = null;
    _resizeStartWidth = 0;
  }

  // Tính tổng số cột đang hiển thị (isShow == true)
  int _getTotalColumnsCount() => _columnList.length;

  /// Index trong `row.cells` (flat đầy đủ, kể cả cột ẩn) tương ứng cột visible.
  int _cellIndexForVisibleColumn(int visibleColumnIndex) {
    final indices = _visibleCellIndices;
    if (visibleColumnIndex < 0 || visibleColumnIndex >= indices.length) {
      return visibleColumnIndex;
    }
    return indices[visibleColumnIndex];
  }

  List<int> get _visibleCellIndices {
    final indices = <int>[];
    var cellIndex = 0;
    for (final column in widget.listViewConfig.columns) {
      if (column.range != null && column.range!.columns.isNotEmpty) {
        if (!column.isShow) {
          cellIndex += column.range!.columns.length;
          continue;
        }
        for (final sub in column.range!.columns) {
          if (sub.isShow) indices.add(cellIndex);
          cellIndex++;
        }
      } else {
        if (column.isShow) indices.add(cellIndex);
        cellIndex++;
      }
    }
    return indices;
  }

  TableColumnConfig? _getGroupColumn(int visibleColumnIndex) {
    var visibleIdx = 0;
    for (final column in widget.listViewConfig.columns) {
      if (column.range != null && column.range!.columns.isNotEmpty) {
        if (!column.isShow) continue;
        final visibleSubs = column.range!.columns
            .where((c) => c.isShow)
            .toList();
        if (visibleSubs.isEmpty) continue;
        final start = visibleIdx;
        final end = visibleIdx + visibleSubs.length - 1;
        if (visibleColumnIndex >= start && visibleColumnIndex <= end) {
          return column.copyWith(
            range: column.range!.copyWith(
              start: start,
              end: end,
              columns: visibleSubs,
            ),
          );
        }
        visibleIdx += visibleSubs.length;
      } else if (column.isShow) {
        visibleIdx++;
      }
    }
    return null;
  }

  List<TableColumnConfig> get _columnList {
    final columnList = <TableColumnConfig>[];

    for (final column in widget.listViewConfig.columns) {
      if (column.range != null && column.range!.columns.isNotEmpty) {
        if (!column.isShow) continue;
        for (final sub in column.range!.columns) {
          if (sub.isShow) columnList.add(sub);
        }
      } else if (column.isShow) {
        columnList.add(column);
      }
    }

    return columnList;
  }

  bool _isGroupedColumn(int visibleColumnIndex) =>
      _getGroupColumn(visibleColumnIndex) != null;

  int? _tableColumnIndexForKey(String key) {
    for (var i = 0; i < _columnList.length; i++) {
      if (_columnList[i].key == key) {
        return widget.listViewConfig.isHaveCheckBox ? i + 1 : i;
      }
    }
    return null;
  }

  double _rawColumnWidth(int actualColumnIndex) {
    if (widget.listViewConfig.isHaveCheckBox && actualColumnIndex == 0) {
      return 60.0;
    }

    final adjustedColumnIndex = widget.listViewConfig.isHaveCheckBox
        ? actualColumnIndex - 1
        : actualColumnIndex;
    if (adjustedColumnIndex >= _columnList.length) {
      return 100.0;
    }

    final columnConfig = _columnList[adjustedColumnIndex];
    if (widget.isUseMaxWidth && columnConfig.maxWidth != 1000.0) {
      return columnConfig.maxWidth.clamp(
        columnConfig.minWidth,
        columnConfig.maxWidth,
      );
    }
    return columnConfig.width;
  }

  double _getColumnWidth(int actualColumnIndex) {
    final raw = _rawColumnWidth(actualColumnIndex);
    final pinnedCount = widget.listViewConfig.fixedLeftColumns;
    if (_viewportWidth <= 0 || actualColumnIndex >= pinnedCount) {
      return raw;
    }

    var pinnedSum = 0.0;
    for (var i = 0; i < pinnedCount; i++) {
      pinnedSum += _rawColumnWidth(i);
    }
    final maxPinned = math.max(
      pinnedCount * 40.0,
      _viewportWidth - _minHorizontalScrollableArea,
    );
    if (pinnedSum <= maxPinned || pinnedSum <= 0) {
      return raw;
    }
    // Scale pinned columns so unpinned area stays scrollable.
    return raw * (maxPinned / pinnedSum);
  }

  double _pinnedColumnsWidth() {
    double width = 0;
    final pinnedCount = widget.listViewConfig.fixedLeftColumns;
    for (int i = 0; i < pinnedCount; i++) {
      width += _getColumnWidth(i);
    }
    return width;
  }
}

/// Notifies only the rows whose hover/selected highlight actually changed.
class _RowHighlightController {
  int hovered = -1;
  final Set<int> _selected = {};
  final Map<int, ValueNotifier<int>> _tokens = {};

  ValueNotifier<int> tokenFor(int rowIndex) {
    return _tokens.putIfAbsent(rowIndex, () => ValueNotifier<int>(0));
  }

  bool isHovered(int rowIndex) => rowIndex == hovered;

  bool isSelected(int rowIndex) => _selected.contains(rowIndex);

  void setHovered(int index) {
    if (hovered == index) return;
    final previous = hovered;
    hovered = index;
    _bump(previous);
    _bump(index);
  }

  void setSelected(int index, bool selected) {
    final changed = selected ? _selected.add(index) : _selected.remove(index);
    if (changed) _bump(index);
  }

  void selectAll(int rowCount) {
    for (var i = 0; i < rowCount; i++) {
      if (_selected.add(i)) _bump(i);
    }
  }

  void clearSelected() {
    if (_selected.isEmpty) return;
    final previous = List<int>.of(_selected);
    _selected.clear();
    for (final index in previous) {
      _bump(index);
    }
  }

  void syncSelected(Set<int> selected) {
    if (_selected.length == selected.length &&
        _selected.containsAll(selected)) {
      return;
    }
    final toNotify = <int>{};
    for (final index in _selected) {
      if (!selected.contains(index)) toNotify.add(index);
    }
    for (final index in selected) {
      if (!_selected.contains(index)) toNotify.add(index);
    }
    _selected
      ..clear()
      ..addAll(selected);
    for (final index in toNotify) {
      _bump(index);
    }
  }

  void _bump(int index) {
    if (index < 0) return;
    final token = _tokens[index];
    if (token != null) token.value++;
  }

  void dispose() {
    for (final token in _tokens.values) {
      token.dispose();
    }
    _tokens.clear();
  }
}

class _RowHighlightBackground extends StatelessWidget {
  const _RowHighlightBackground({
    required this.controller,
    required this.rowIndex,
    required this.idleColor,
    required this.hoverColor,
    required this.selectedColor,
    required this.onEnter,
    required this.child,
  });

  final _RowHighlightController controller;
  final int rowIndex;
  final Color idleColor;
  final Color hoverColor;
  final Color selectedColor;
  final VoidCallback onEnter;
  final Widget child;

  Color _colorForRow() {
    if (controller.isSelected(rowIndex)) return selectedColor;
    if (controller.isHovered(rowIndex)) return hoverColor;
    return idleColor;
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      opaque: false,
      onEnter: (_) => onEnter(),
      child: ValueListenableBuilder<int>(
        valueListenable: controller.tokenFor(rowIndex),
        builder: (context, _, child) {
          return ColoredBox(
            color: _colorForRow(),
            child: SizedBox.expand(child: child),
          );
        },
        child: child,
      ),
    );
  }
}
