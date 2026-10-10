import NoteCraftCore
import PDFKit
import SwiftUI

struct PDFFormField: Identifiable {
  var id: Int { annotationIndex }
  let annotationIndex: Int
  let name: String
  let checkbox: Bool
  let choices: [String]
  var value: String
  var checked: Bool
}

@MainActor enum PDFForms {
  static func fields(_ data: Data, pageIndex: Int) -> [PDFFormField] {
    guard let page = PDFDocument(data: data)?.page(at: pageIndex) else { return [] }
    return page.annotations.enumerated().compactMap { index, annotation in
      guard annotation.type == "Widget", !annotation.isReadOnly else { return nil }
      let text = annotation.widgetFieldType == .text
      let choice = annotation.widgetFieldType == .choice
      let checkbox =
        annotation.widgetFieldType == .button && annotation.widgetControlType == .checkBoxControl
      guard text || choice || checkbox else { return nil }
      return PDFFormField(
        annotationIndex: index, name: annotation.fieldName ?? "Field \(index + 1)",
        checkbox: checkbox, choices: annotation.choices ?? [],
        value: annotation.widgetStringValue ?? "",
        checked: annotation.buttonWidgetState == .onState)
    }
  }
  static func apply(_ fields: [PDFFormField], to data: Data, pageIndex: Int) throws -> Data {
    guard let pdf = PDFDocument(data: data), let page = pdf.page(at: pageIndex) else {
      throw PackageError.invalidPackage
    }
    for field in fields {
      guard page.annotations.indices.contains(field.annotationIndex) else {
        throw PackageError.invalidPackage
      }
      let annotation = page.annotations[field.annotationIndex]
      guard !annotation.isReadOnly, annotation.type == "Widget" else {
        throw PackageError.invalidPackage
      }
      if field.checkbox {
        annotation.buttonWidgetState = field.checked ? .onState : .offState
      } else {
        annotation.widgetStringValue = field.value
      }
    }
    guard let result = pdf.dataRepresentation() else { throw PackageError.invalidPackage }
    return result
  }
}

struct PDFFormsSheet: View {
  let package: NotebookPackage
  let page: Page
  let onSave: ([String: Data]) -> Void
  @State private var fields: [PDFFormField] = []
  @State private var error: String?
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    NavigationStack {
      Form {
        if fields.isEmpty {
          ContentUnavailableView(
            "No editable fields on this page", systemImage: "doc.text",
            description: Text(
              "Text fields, choices and checkboxes are supported. Signature and radio fields need another PDF editor."
            ))
        }
        ForEach($fields) { $field in
          if field.checkbox {
            Toggle(field.name, isOn: $field.checked)
          } else if !field.choices.isEmpty {
            Picker(field.name, selection: $field.value) {
              if !field.choices.contains(field.value) {
                Text(field.value.isEmpty ? "Choose…" : field.value).tag(field.value)
              }
              ForEach(field.choices, id: \.self) { Text($0).tag($0) }
            }
          } else {
            TextField(field.name, text: $field.value, axis: .vertical)
          }
        }
        if let error { Text(error).foregroundStyle(.red) }
      }.navigationTitle("PDF form fields")
        .toolbar {
          ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
          ToolbarItem(placement: .confirmationAction) {
            Button("Save") {
              do {
                guard let name = page.backgroundPDF, let data = package.assets[name] else {
                  throw PackageError.invalidPackage
                }
                onSave([
                  name: try PDFForms.apply(fields, to: data, pageIndex: page.backgroundPage ?? 0)
                ])
                dismiss()
              } catch { self.error = error.localizedDescription }
            }.disabled(fields.isEmpty)
          }
        }
    }.frame(minWidth: 380, minHeight: 420).preferredColorScheme(.light)
      .onAppear {
        if let name = page.backgroundPDF, let data = package.assets[name] {
          fields = PDFForms.fields(data, pageIndex: page.backgroundPage ?? 0)
        }
      }
  }
}
