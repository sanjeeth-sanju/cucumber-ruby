module Cucumber
  module Formatter

    FormatterWrapper = Struct.new(:formatter) do
      def method_missing(message, *args)
        formatter.send(message, *args) if formatter.respond_to?(message)
      end
    end

    ReportAdapter = Struct.new(:runtime, :formatter) do
      def initialize(runtime, formatter)
        super runtime, FormatterWrapper.new(formatter)
      end

      def before_test_case(test_case)
      end

      def before_test_step(test_step)
      end

      def after_test_step(test_step, result)
        test_step.describe_source_to(printer, result)
      end

      def after_test_case(test_case, result)
        record_test_case_result(result)
      end

      def after_suite
        printer.after
      end

      private

      def printer
        @printer ||= FeaturesPrinter.new(formatter, runtime).before
      end

      # Provides a DSL for making the printers themselves more terse
      class Printer < Struct
        def self.before(&block)
          define_method(:before) do
            instance_eval(&block)
            self
          end
        end

        def self.after(&block)
          define_method(:after) do
            @child.after if @child
            instance_eval(&block)
            self
          end
        end

        def open(printer_type, node)
          args = [formatter, runtime, node]
          @child.after if @child
          @child = printer_type.new(*args).before
        end

        def method_missing(message, *args)
          raise "#{self.class} has no @child to send '#{message}' to. Perhaps you need to implement it?" unless @child
          return super unless @child.respond_to?(message)
          @child.send(message, *args)
        end

        def respond_to_missing?(message, include_private = false)
          @child.respond_to?(message, include_private) || super
        end

        def for_new(node, &block)
          @current_nodes ||= {}
          if @current_nodes[node.class] != node
            @current_nodes[node.class] = node
            block.call
          end
        end
      end

      FeaturesPrinter = Printer.new(:formatter, :runtime) do
        before do
          formatter.before_features(nil)
        end

        def hook(*); end

        def feature(feature, *)
          for_new(feature) do
            open FeaturePrinter, feature
          end
        end

        after do
          formatter.after_features(nil)
        end
      end

      FeaturePrinter = Printer.new(:formatter, :runtime, :feature) do
        before do
          formatter.before_feature(feature)
          feature.tags.accept TagPrinter.new(formatter)
          formatter.feature_name(feature.keyword, feature.name)
        end

        def background(background, *)
          open BackgroundPrinter, background
        end

        def scenario(scenario, *)
          for_new(scenario) do
            open ScenarioPrinter, scenario
          end
        end

        def scenario_outline(scenario_outline, *)
          for_new(scenario_outline) do
            open ScenarioOutlinePrinter, scenario_outline
          end
        end

        after do
          formatter.after_feature
        end
      end

      BackgroundPrinter = Printer.new(:formatter, :runtime, :background) do
        before do
          formatter.before_background(background)
          source_indent = 1 # TODO
          formatter.background_name(background.keyword, background.name, background.location.to_s, source_indent)
        end

        def step(step, result)
          @child ||= StepsPrinter.new(formatter).before
          step_result = LegacyResultBuilder.new(result).step_result(background)
          runtime.step_visited step_result
          @child.step step, step_result, runtime, background
        end

        after do
          formatter.after_background(background)
        end

        private

        def step_result(result, background)
        end
      end

      ScenarioPrinter = Printer.new(:formatter, :runtime, :scenario) do
        before do
          formatter.before_feature_element(scenario)
          scenario.tags.accept TagPrinter.new(formatter)
          source_indent = 1 # TODO
          formatter.scenario_name(scenario.keyword, scenario.name, scenario.location.to_s, source_indent)
        end

        def step(step, result)
          @child ||= StepsPrinter.new(formatter).before
          step_result = LegacyResultBuilder.new(result).step_result
          runtime.step_visited step_result
          @child.step step, step_result, runtime
        end

        after do
          formatter.after_feature_element(scenario)
        end

        private

        def step_result(result, background)
          LegacyResultBuilder.new(result).step_result(background)
        end
      end

      StepsPrinter = Printer.new(:formatter) do
        before do
          formatter.before_steps
        end

        def step(step, step_result, runtime, background = nil)
          StepPrinter.new(formatter, runtime, step, step_result, background).print
        end

        after do
          formatter.after_steps
        end
      end

      StepPrinter = Struct.new(:formatter, :runtime, :step, :step_result, :background) do

        def print
          formatter.before_step(legacy_step)
          formatter.before_step_result(step_result)
          print_step
          print_multiline_arg
          formatter.after_step_result
          formatter.after_step(legacy_step)
        end

        private

        def print_step
          source_indent = 1 # TODO
          formatter.step_name(step.keyword, step_match(step), step_result.status, source_indent, background, step.location.to_s)
        end

        def print_multiline_arg
          return unless step.multiline_arg
          printer = MultilineArgPrinter.new(formatter, runtime, step.multiline_arg).before
          step.describe_to printer
          printer.after
        end

        def step_match(step)
          runtime.step_match(step.name)
        rescue Cucumber::Undefined
          NoStepMatch.new(step, step.name)
        end

        def legacy_step
          LegacyStep.new(step_result)
        end

        LegacyStep = Struct.new(:step_result) do
          def status
            step_result.status
          end
        end

      end

      MultilineArgPrinter = Printer.new(:formatter, :runtime, :node) do
        before do
          formatter.before_multiline_arg node
        end

        def step(step, &descend)
          descend.call
        end

        def outline_step(outline_step, &descend)
          descend.call
        end

        def doc_string(doc_string)
          formatter.doc_string(doc_string)
        end

        def table(table)
          table.raw.each do |row|
            TableRowPrinter.new(formatter, runtime, row).before.after
          end
        end

        after do
          formatter.after_multiline_arg node
        end
      end

      ScenarioOutlinePrinter = Printer.new(:formatter, :runtime, :node) do
        before do
          formatter.before_feature_element(node)
          node.tags.accept TagPrinter.new(formatter)
          source_indent = 1 # TODO
          formatter.scenario_name(node.keyword, node.name, node.location.to_s, source_indent)
          outline_steps_printer = OutlineStepsPrinter.new(formatter, runtime)
          node.describe_to outline_steps_printer
          outline_steps_printer.after
        end

        def examples_table(examples_table, *)
          @child ||= ExamplesArrayPrinter.new(formatter, runtime).before
          @child.examples_table(examples_table)
        end

        after do
          formatter.after_feature_element(node)
        end
      end

      OutlineStepsPrinter = Struct.new(:formatter, :runtime) do
        def scenario_outline(node, &descend)
          descend.call # print the outline steps
        end

        def outline_step(step)
          step_result = LegacyResultBuilder.new(Core::Test::Result::Skipped.new).step_result(background = nil)
          steps_printer.step step, step_result, runtime, background = nil
        end

        def examples_table(*);end

        def after
          steps_printer.after
        end

        private

        def steps_printer
          @steps_printer ||= StepsPrinter.new(formatter).before
        end
      end

      ExamplesArrayPrinter = Printer.new(:formatter, :runtime) do
        before do
          formatter.before_examples_array(:examples_array)
        end

        def examples_table(examples_table)
          for_new(examples_table) do
            open ExamplesTablePrinter, examples_table
          end
        end

        after do
          formatter.after_examples_array
        end
      end

      ExamplesTablePrinter = Printer.new(:formatter, :runtime, :node) do
        before do
          formatter.before_examples(node)
          formatter.examples_name(node.keyword, node.name)
          formatter.before_outline_table(node)
          TableRowPrinter.new(formatter, runtime, node.header).before.after
        end

        def examples_table_row(examples_table_row, *)
          for_new(examples_table_row) do
            open TableRowPrinter, examples_table_row
          end
        end

        after do
          formatter.after_outline_table(node)
          formatter.after_examples(node)
        end
      end

      TableRowPrinter = Printer.new(:formatter, :runtime, :node, :background) do
        before do
          formatter.before_table_row(node)
        end

        def step(step, result)
          record_step_result result
        end

        after do
          each_value do |value|
            formatter.before_table_cell(value)
            formatter.table_cell_value(value, :skipped) # TODO: set the status somehow
            formatter.after_table_cell(value)
          end
          formatter.after_table_row(legacy_table_row)
        end

        private

        def record_step_result(result)
          return @step_result if @step_result
          step_result = LegacyResultBuilder.new(result).step_result(background = nil)
          runtime.step_visited step_result
          @step_result = step_result
        end

        def legacy_table_row
          LegacyTableRow.new(node, @step_result)
        end

        def each_value(&block)
          # TODO: resolve this inconsistency between DataTable and ExamplesTable
          if node.respond_to?(:values)
            node.values.each(&block)
          else
            node.each(&block)
          end
        end

        LegacyTableRow = Struct.new(:node, :step_result) do
          def exception
            nil # TODO
          end
        end
      end

      TagPrinter = Struct.new(:formatter) do
        def visit_tags(tags)
          formatter.before_tags tags
          tags.tags.each do |tag|
            formatter.visit_tag_name tag.name
          end
          formatter.after_tags tags
        end
      end

      def record_test_case_result(result)
        scenario = LegacyResultBuilder.new(result).scenario
        runtime.record_result(scenario)
        yield scenario if block_given?
      end

      require 'cucumber/ast/step_result'
      class LegacyResultBuilder
        def initialize(result)
          result.describe_to(self)
        end

        def passed
          @status = :passed
        end

        def failed
          @status = :failed
        end

        def undefined
          @status = :undefined
        end

        def skipped
          @status = :skipped
        end

        def exception(exception, *)
          @exception = exception
        end

        def duration(*); end

        def step_result(background = nil)
          Ast::StepResult.new(:keyword, :step_match, :multiline_arg, @status, @exception, :source_indent, background, :file_colon_line)
        end

        def scenario
          LegacyScenario.new(@status)
        end

        LegacyScenario = Struct.new(:status)
      end

    end
  end
end