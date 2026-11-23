module Opml
  class ImportJob
    include Sidekiq::Job

    sidekiq_options queue: "ingestion", retry: 3

    def perform(opml_import_id, serialized_outlines)
      opml_import = OpmlImport.find_by(id: opml_import_id)
      return unless opml_import

      Opml::Import.process!(opml_import, serialized_outlines)
    end
  end
end
