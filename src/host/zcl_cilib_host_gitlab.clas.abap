"! GitLab host
"! <p>
"! https://docs.gitlab.com/ce/api/
"! </p>
"! Some notes:
"! <ul>
"!   <li>GitLab calls Pull Requests (PR) Merge Requests (MR)</li>
"!   <li>GitLab calls comments notes</li>
"!   <li>GitLab differentiates between issues notes and merge request notes. Only merge request notes are
"!       relevant here for now.</li>
"! </ul>
CLASS zcl_cilib_host_gitlab DEFINITION
  PUBLIC
  FINAL
  CREATE PRIVATE
  GLOBAL FRIENDS zcl_cilib_factory.

  PUBLIC SECTION.
    INTERFACES:
      zif_cilib_host.
    METHODS:
      constructor IMPORTING iv_host_path   TYPE zcilib_host_hostpath
                            io_host_config TYPE REF TO zcl_cilib_host_config
                  RAISING   zcx_cilib_illegal_argument,
      get_repo_id_for_repo IMPORTING iv_repository TYPE csequence
                           RETURNING VALUE(rv_id)  TYPE i
                           RAISING   zcx_cilib_http_comm_error
                                     zcx_cilib_not_found.
  PROTECTED SECTION.
  PRIVATE SECTION.
    CONSTANTS:
      gc_api_base_path TYPE string VALUE `/api/v4`,
      BEGIN OF gc_endpoints,
        projects TYPE string VALUE `projects`,
      END OF gc_endpoints,
      BEGIN OF gc_project_attributes,
        id                  TYPE string VALUE 'ID',
        path_with_namespace TYPE string VALUE `PATH_WITH_NAMESPACE`,
      END OF gc_project_attributes,
      BEGIN OF gc_project_parameters,
        simple TYPE string VALUE `simple`,
        search TYPE string VALUE `search`,
      END OF gc_project_parameters,
      BEGIN OF gc_project_subpaths,
        repo_branches  TYPE string VALUE `repository/branches`,
        merge_requests TYPE string VALUE `merge_requests`,
        wikis          TYPE string VALUE `wikis`,
      END OF gc_project_subpaths,
      BEGIN OF gc_branch_attributes,
        name TYPE string VALUE `NAME`,
      END OF gc_branch_attributes,
      BEGIN OF gc_merge_request_parameters,
        source_branch TYPE string VALUE `source_branch`,
        target_branch TYPE string VALUE `target_branch`,
      END OF gc_merge_request_parameters,
      BEGIN OF gc_merge_request_attributes,
        iid    TYPE string VALUE `IID`,
        labels TYPE string VALUE 'LABELS',
      END OF gc_merge_request_attributes,
      BEGIN OF gc_merge_request_subpaths,
        notes TYPE string VALUE `notes`,
      END OF gc_merge_request_subpaths,
      BEGIN OF gc_merge_request_put_attrs,
        id                TYPE string VALUE `ID`,
        merge_request_iid TYPE string VALUE `MERGE_REQUEST_IID`,
        labels            TYPE string VALUE `LABELS`,
      END OF gc_merge_request_put_attrs,
      BEGIN OF gc_note_attributes,
        id     TYPE string VALUE `ID`,
        author TYPE string VALUE `AUTHOR`,
        body   TYPE string VALUE `BODY`,
      END OF gc_note_attributes,
      BEGIN OF gc_note_parameters,
        body TYPE string VALUE `body`,
      END OF gc_note_parameters,
      BEGIN OF gc_author_attributes,
        username TYPE string VALUE `USERNAME`,
      END OF gc_author_attributes,
      BEGIN OF gc_wiki_page_attributes,
        name    TYPE string VALUE `SLUG`,
        title   TYPE string VALUE `TITLE`,
        format  TYPE string VALUE `FORMAT`,
        content TYPE string VALUE `CONTENT`,
      END OF gc_wiki_page_attributes,
      gc_header_private_token TYPE string VALUE `Private-Token`,
      BEGIN OF gc_parameter_bool,
        true  TYPE string VALUE `true`,
        false TYPE string VALUE `false`,
      END OF gc_parameter_bool,
      gc_error_message_attribute  TYPE string VALUE `MESSAGE`,
      gc_error_message_attribute2 TYPE string VALUE `ERROR`.
    METHODS:
      get_last_error_text RETURNING VALUE(rv_text) TYPE string,
      authenticate_if_needed RAISING zcx_cilib_http_comm_error.
    DATA:
      mi_rest_client TYPE REF TO if_rest_client,
      mi_http_client TYPE REF TO if_http_client,
      mo_config      TYPE REF TO zcl_cilib_host_config,
      mv_host_path   TYPE zcilib_host_hostpath.
ENDCLASS.



CLASS zcl_cilib_host_gitlab IMPLEMENTATION.
  METHOD constructor.
    mo_config = io_host_config.
    mv_host_path = iv_host_path.

    cl_http_client=>create_by_destination(
      EXPORTING
        destination              = mo_config->get_rfc_destination( )
      IMPORTING
        client                   = mi_http_client
      EXCEPTIONS
        argument_not_found       = 1
        destination_not_found    = 2
        destination_no_authority = 3
        plugin_not_active        = 4
        internal_error           = 5
        OTHERS                   = 6
    ).
    IF sy-subrc <> 0.
      RAISE EXCEPTION TYPE zcx_cilib_illegal_argument
        EXPORTING
          is_msg = zcl_cilib_util_msg_tools=>get_msg_from_sy( ).
    ENDIF.
    mi_http_client->propertytype_logon_popup = if_http_client=>co_disabled.
    mi_rest_client = NEW cl_rest_http_client( mi_http_client ).
  ENDMETHOD.

  METHOD zif_cilib_host~does_repo_exist.
    TRY.
        get_repo_id_for_repo( iv_repository ).
        rv_exists = abap_true.
      CATCH zcx_cilib_not_found.
        rv_exists = abap_false.
    ENDTRY.
  ENDMETHOD.

  METHOD get_repo_id_for_repo.
    DATA: lv_namespace TYPE string,
          lv_repo_name TYPE string.
    " https://docs.gitlab.com/ce/api/projects.html#list-all-projects

    authenticate_if_needed( ).

    " The API does not seem to allow searching for the fully qualified repo name including the user / group directly.
    " -> Search for repository name only and filter afterwards
    IF iv_repository CS '/'.
      SPLIT iv_repository AT '/' INTO lv_namespace lv_repo_name.
    ELSE.
      RAISE EXCEPTION TYPE zcx_cilib_not_found
        EXPORTING
          is_textid    = zcx_cilib_not_found=>gc_with_name_and_key
          iv_type_name = 'Repository'
          iv_key       = iv_repository.
    ENDIF.

    TRY.
        DATA(lv_path) = NEW zcl_cilib_http_path_builder( gc_api_base_path
          )->append_path_component( gc_endpoints-projects
          )->add_parameter( iv_name = gc_project_parameters-simple iv_value = gc_parameter_bool-true
          )->add_parameter( iv_name = gc_project_parameters-search iv_value = lv_repo_name
          )->build( ).

        mi_rest_client->set_request_header( iv_name = if_http_header_fields_sap=>request_uri iv_value = lv_path ).
        mi_rest_client->get( ).
        DATA(lv_status) = mi_rest_client->get_status( ).

        IF lv_status <> 200.
          RAISE EXCEPTION TYPE zcx_cilib_http_comm_error
            EXPORTING
              is_textid        = zcx_cilib_http_comm_error=>gc_code_and_message
              iv_response_code = lv_status
              iv_error_message = get_last_error_text( ).
        ENDIF.

        DATA(li_response) = mi_rest_client->get_response_entity( ).
        DATA(lo_json) = CAST zcl_cilib_util_json_array(
          zcl_cilib_util_json_parser=>create_from_xstring( li_response->get_binary_data( ) )
        ).

        IF lo_json->get_count( ) <> 1.
          RAISE EXCEPTION TYPE zcx_cilib_not_found
            EXPORTING
              is_textid    = zcx_cilib_not_found=>gc_with_name_and_key
              iv_type_name = 'Repository'
              iv_key       = iv_repository.
        ENDIF.

        DATA(lo_child) = CAST zcl_cilib_util_json_object( lo_json->get_element_at( 1 ) ).
        DATA(lv_path_with_namespace) = lo_child->get_string( gc_project_attributes-path_with_namespace ).
        IF to_lower( iv_repository ) = to_lower( lv_path_with_namespace ).
          rv_id = lo_child->get_int( gc_project_attributes-id ).
        ENDIF.

      CATCH cx_rest_client_exception INTO DATA(lx_ex).
        RAISE EXCEPTION TYPE zcx_cilib_http_comm_error
          EXPORTING
            is_msg      = zcl_cilib_util_msg_tools=>get_msg_from_string( get_last_error_text( ) )
            ix_previous = lx_ex.
    ENDTRY.
  ENDMETHOD.

  METHOD zif_cilib_host~get_pull_request_for_branch.
    " https://docs.gitlab.com/ce/api/merge_requests.html

    authenticate_if_needed( ).

    TRY.
        DATA(lv_path) = NEW zcl_cilib_http_path_builder( gc_api_base_path
          )->append_path_component( gc_endpoints-projects
          )->append_escaped_path_component( iv_repository "get_repo_id_for_repo( iv_repository )
          )->append_path_component( gc_project_subpaths-merge_requests
          )->add_parameter( iv_name = gc_merge_request_parameters-source_branch iv_value = iv_branch
          )->add_parameter( iv_name = gc_merge_request_parameters-target_branch iv_value = 'master' ##TODO
          )->build( ).

        mi_rest_client->set_request_header( iv_name = if_http_header_fields_sap=>request_uri iv_value = lv_path ).
        mi_rest_client->get( ).
        DATA(lv_status) = mi_rest_client->get_status( ).

        IF lv_status = 404.
          RAISE EXCEPTION TYPE zcx_cilib_not_found
            EXPORTING
              is_textid    = zcx_cilib_not_found=>gc_with_name_and_key
              iv_type_name = 'Repository'
              iv_key       = iv_repository.
        ELSEIF lv_status <> 200.
          RAISE EXCEPTION TYPE zcx_cilib_http_comm_error
            EXPORTING
              is_textid        = zcx_cilib_http_comm_error=>gc_code_and_message
              iv_response_code = lv_status
              iv_error_message = get_last_error_text( ).
        ENDIF.

        DATA(li_response) = mi_rest_client->get_response_entity( ).
        DATA(lo_json) = CAST zcl_cilib_util_json_array(
          zcl_cilib_util_json_parser=>create_from_xstring( li_response->get_binary_data( ) )
        ).

        IF lo_json->get_count( ) <> 1.
          RAISE EXCEPTION TYPE zcx_cilib_not_found
            EXPORTING
              is_textid    = zcx_cilib_not_found=>gc_with_name_and_key
              iv_type_name = 'Pull Request'
              it_keys      = VALUE #( ( iv_repository ) ( iv_branch ) ( `master` ) ).
        ENDIF.

        DATA(lo_child) = CAST zcl_cilib_util_json_object( lo_json->get_element_at( 1 ) ).
        rv_pull_request = lo_child->get_int( gc_merge_request_attributes-iid ).

      CATCH cx_rest_client_exception INTO DATA(lx_ex).
        RAISE EXCEPTION TYPE zcx_cilib_http_comm_error
          EXPORTING
            is_msg      = zcl_cilib_util_msg_tools=>get_msg_from_string( get_last_error_text( ) )
            ix_previous = lx_ex.
    ENDTRY.
  ENDMETHOD.

  METHOD zif_cilib_host~create_pr_comment.
    " https://docs.gitlab.com/ce/api/notes.html#create-new-merge-request-note

    authenticate_if_needed( ).

    TRY.
        DATA(lv_path) = NEW zcl_cilib_http_path_builder( gc_api_base_path
          )->append_path_component( gc_endpoints-projects
          )->append_escaped_path_component( iv_repository "get_repo_id_for_repo( iv_repository )
          )->append_path_component( gc_project_subpaths-merge_requests
          )->append_path_component( iv_pull_request
          )->append_path_component( gc_merge_request_subpaths-notes
          )->add_parameter( iv_name = gc_note_parameters-body iv_value = iv_content
          )->build( ).

        mi_rest_client->set_request_header( iv_name = if_http_header_fields_sap=>request_uri iv_value = lv_path ).
        mi_rest_client->post( mi_rest_client->create_request_entity( ) ).
        DATA(lv_status) = mi_rest_client->get_status( ).

        IF lv_status = 404.
          RAISE EXCEPTION TYPE zcx_cilib_not_found
            EXPORTING
              is_textid    = zcx_cilib_not_found=>gc_with_name_and_key
              iv_type_name = 'Pull Request'
              it_keys      = VALUE #( ( iv_repository ) ( CONV #( iv_pull_request ) ) ).
        ELSEIF lv_status <> 201.
          RAISE EXCEPTION TYPE zcx_cilib_http_comm_error
            EXPORTING
              is_textid        = zcx_cilib_http_comm_error=>gc_code_and_message
              iv_response_code = lv_status
              iv_error_message = get_last_error_text( ).
        ENDIF.

      CATCH cx_rest_client_exception INTO DATA(lx_ex).
        RAISE EXCEPTION TYPE zcx_cilib_http_comm_error
          EXPORTING
            is_msg      = zcl_cilib_util_msg_tools=>get_msg_from_string( get_last_error_text( ) )
            ix_previous = lx_ex.
    ENDTRY.
  ENDMETHOD.

  METHOD zif_cilib_host~get_comments_for_pull_request.
    " https://docs.gitlab.com/ce/api/notes.html#list-all-merge-request-notes

    authenticate_if_needed( ).

    TRY.
        DATA(lv_path) = NEW zcl_cilib_http_path_builder( gc_api_base_path
          )->append_path_component( gc_endpoints-projects
          )->append_escaped_path_component( iv_repository "get_repo_id_for_repo( iv_repository )
          )->append_path_component( gc_project_subpaths-merge_requests
          )->append_path_component( iv_pull_request
          )->append_path_component( gc_merge_request_subpaths-notes
          )->build( ).

        mi_rest_client->set_request_header( iv_name = if_http_header_fields_sap=>request_uri iv_value = lv_path ).
        mi_rest_client->get( ).
        DATA(lv_status) = mi_rest_client->get_status( ).

        IF lv_status = 404.
          RAISE EXCEPTION TYPE zcx_cilib_not_found
            EXPORTING
              is_textid    = zcx_cilib_not_found=>gc_with_name_and_key
              iv_type_name = 'Pull Request'
              it_keys      = VALUE #( ( iv_repository ) ( CONV #( iv_pull_request ) ) ).
        ELSEIF lv_status <> 200.
          RAISE EXCEPTION TYPE zcx_cilib_http_comm_error
            EXPORTING
              is_textid        = zcx_cilib_http_comm_error=>gc_code_and_message
              iv_response_code = lv_status
              iv_error_message = get_last_error_text( ).
        ENDIF.

        DATA(li_response) = mi_rest_client->get_response_entity( ).
        DATA(lo_json) = CAST zcl_cilib_util_json_array(
          zcl_cilib_util_json_parser=>create_from_xstring( li_response->get_binary_data( ) )
        ).

        DO lo_json->get_count( ) TIMES.
          DATA(lo_child) = CAST zcl_cilib_util_json_object( lo_json->get_element_at( sy-index ) ).
          DATA(lv_author) = lo_child->get_object( gc_note_attributes-author
            )->get_string( gc_author_attributes-username ).
          IF iv_by_author IS INITIAL OR lv_author = iv_by_author.
            APPEND VALUE #(
              id     = lo_child->get_int( gc_note_attributes-id )
              author = lv_author
            ) TO rt_comments.
          ENDIF.
        ENDDO.

      CATCH cx_rest_client_exception INTO DATA(lx_ex).
        RAISE EXCEPTION TYPE zcx_cilib_http_comm_error
          EXPORTING
            is_msg      = zcl_cilib_util_msg_tools=>get_msg_from_string( get_last_error_text( ) )
            ix_previous = lx_ex.
    ENDTRY.
  ENDMETHOD.

  METHOD zif_cilib_host~get_pr_comment_content.
    " https://docs.gitlab.com/ce/api/notes.html#get-single-merge-request-note

    authenticate_if_needed( ).

    TRY.
        DATA(lv_path) = NEW zcl_cilib_http_path_builder( gc_api_base_path
          )->append_path_component( gc_endpoints-projects
          )->append_escaped_path_component( iv_repository "get_repo_id_for_repo( iv_repository )
          )->append_path_component( gc_project_subpaths-merge_requests
          )->append_path_component( iv_pull_request
          )->append_path_component( gc_merge_request_subpaths-notes
          )->append_path_component( iv_comment
          )->build( ).

        mi_rest_client->set_request_header( iv_name = if_http_header_fields_sap=>request_uri iv_value = lv_path ).
        mi_rest_client->get( ).
        DATA(lv_status) = mi_rest_client->get_status( ).

        IF lv_status = 404.
          RAISE EXCEPTION TYPE zcx_cilib_not_found
            EXPORTING
              is_textid    = zcx_cilib_not_found=>gc_with_name_and_key
              iv_type_name = 'PR Comment'
              it_keys      = VALUE #( ( iv_repository ) ( CONV #( iv_pull_request ) ) ( CONV #( iv_comment ) ) ).
        ELSEIF lv_status <> 200.
          RAISE EXCEPTION TYPE zcx_cilib_http_comm_error
            EXPORTING
              is_textid        = zcx_cilib_http_comm_error=>gc_code_and_message
              iv_response_code = lv_status
              iv_error_message = get_last_error_text( ).
        ENDIF.

        DATA(li_response) = mi_rest_client->get_response_entity( ).
        DATA(lo_json) = CAST zcl_cilib_util_json_object(
          zcl_cilib_util_json_parser=>create_from_xstring( li_response->get_binary_data( ) )
        ).

        rv_content = lo_json->get_string(
          iv_name                     = gc_note_attributes-body
          iv_replace_unicode_entities = abap_true
        ).

      CATCH cx_rest_client_exception INTO DATA(lx_ex).
        RAISE EXCEPTION TYPE zcx_cilib_http_comm_error
          EXPORTING
            is_msg      = zcl_cilib_util_msg_tools=>get_msg_from_string( get_last_error_text( ) )
            ix_previous = lx_ex.
    ENDTRY.
  ENDMETHOD.

  METHOD zif_cilib_host~get_repo_branches.
    " https://docs.gitlab.com/ce/api/branches.html

    authenticate_if_needed( ).

    TRY.
        DATA(lv_path) = NEW zcl_cilib_http_path_builder( gc_api_base_path
          )->append_path_component( gc_endpoints-projects
          )->append_escaped_path_component( iv_repository "get_repo_id_for_repo( iv_repository )
          )->append_path_component( gc_project_subpaths-repo_branches
          )->build( ).

        mi_rest_client->set_request_header( iv_name = if_http_header_fields_sap=>request_uri iv_value = lv_path ).
        mi_rest_client->get( ).
        DATA(lv_status) = mi_rest_client->get_status( ).

        IF lv_status = 404.
          RAISE EXCEPTION TYPE zcx_cilib_not_found
            EXPORTING
              is_textid    = zcx_cilib_not_found=>gc_with_name_and_key
              iv_type_name = 'Repository'
              iv_key       = iv_repository.
        ELSEIF lv_status <> 200.
          RAISE EXCEPTION TYPE zcx_cilib_http_comm_error
            EXPORTING
              is_textid        = zcx_cilib_http_comm_error=>gc_code_and_message
              iv_response_code = lv_status
              iv_error_message = get_last_error_text( ).
        ENDIF.

        DATA(li_response) = mi_rest_client->get_response_entity( ).
        DATA(lo_json) = CAST zcl_cilib_util_json_array(
          zcl_cilib_util_json_parser=>create_from_xstring( li_response->get_binary_data( ) )
        ).

        DO lo_json->get_count( ) TIMES.
          DATA(lo_child) = CAST zcl_cilib_util_json_object( lo_json->get_element_at( sy-index ) ).
          APPEND lo_child->get_string( gc_branch_attributes-name ) TO rt_branches.
        ENDDO.

      CATCH cx_rest_client_exception INTO DATA(lx_ex).
        RAISE EXCEPTION TYPE zcx_cilib_http_comm_error
          EXPORTING
            is_msg      = zcl_cilib_util_msg_tools=>get_msg_from_string( get_last_error_text( ) )
            ix_previous = lx_ex.
    ENDTRY.
  ENDMETHOD.

  METHOD zif_cilib_host~set_pr_comment_content.
    " https://docs.gitlab.com/ce/api/notes.html#modify-existing-merge-request-note

    authenticate_if_needed( ).

    TRY.
        DATA(lv_path) = NEW zcl_cilib_http_path_builder( gc_api_base_path
          )->append_path_component( gc_endpoints-projects
          )->append_escaped_path_component( iv_repository "get_repo_id_for_repo( iv_repository )
          )->append_path_component( gc_project_subpaths-merge_requests
          )->append_path_component( iv_pull_request
          )->append_path_component( gc_merge_request_subpaths-notes
          )->append_path_component( iv_comment
          )->add_parameter( iv_name = gc_note_parameters-body iv_value = iv_content
          )->build( ).

        mi_rest_client->set_request_header( iv_name = if_http_header_fields_sap=>request_uri iv_value = lv_path ).
        mi_rest_client->put( mi_rest_client->create_request_entity( ) ).
        DATA(lv_status) = mi_rest_client->get_status( ).

        IF lv_status = 404.
          RAISE EXCEPTION TYPE zcx_cilib_not_found
            EXPORTING
              is_textid    = zcx_cilib_not_found=>gc_with_name_and_key
              iv_type_name = 'PR Comment'
              it_keys      = VALUE #( ( iv_repository ) ( CONV #( iv_pull_request ) ) ( CONV #( iv_comment ) ) ).
        ELSEIF lv_status <> 200.
          RAISE EXCEPTION TYPE zcx_cilib_http_comm_error
            EXPORTING
              is_textid        = zcx_cilib_http_comm_error=>gc_code_and_message
              iv_response_code = lv_status
              iv_error_message = get_last_error_text( ).
        ENDIF.

      CATCH cx_rest_client_exception INTO DATA(lx_ex).
        RAISE EXCEPTION TYPE zcx_cilib_http_comm_error
          EXPORTING
            is_msg      = zcl_cilib_util_msg_tools=>get_msg_from_string( get_last_error_text( ) )
            ix_previous = lx_ex.
    ENDTRY.
  ENDMETHOD.

  METHOD zif_cilib_host~authenticate.
    " https://docs.gitlab.com/ce/api/#personal-access-tokens
    " Authentication using RFC destination is not possible as HTTP Basic Authentication is not allowed for API calls.
    " Access tokens should be the easiest way to do things. Since they are transmitted in every request this method
    " only serves as a validation that the token is correct.

    IF zif_cilib_host~mv_is_authenticated = abap_true.
      RETURN.
    ENDIF.

    TRY.
        DATA(lv_dummy_request_path) = NEW zcl_cilib_http_path_builder( gc_api_base_path
          )->append_path_component( gc_endpoints-projects
          )->build( ).
        mi_rest_client->set_request_header( iv_name = gc_header_private_token iv_value = mo_config->get_api_token( ) ).
        mi_rest_client->set_request_header( iv_name  = if_http_header_fields_sap=>request_uri
                                            iv_value = lv_dummy_request_path ).
        mi_rest_client->get( ).
        DATA(lv_status) = mi_rest_client->get_status( ).
        IF lv_status = 200.
          zif_cilib_host~mv_is_authenticated = abap_true.
        ELSE.
          RAISE EXCEPTION TYPE zcx_cilib_http_comm_error
            EXPORTING
              is_textid        = zcx_cilib_http_comm_error=>gc_code_and_message
              iv_response_code = lv_status
              iv_error_message = get_last_error_text( ).
        ENDIF.

      CATCH cx_rest_client_exception INTO DATA(lx_ex).
        RAISE EXCEPTION TYPE zcx_cilib_http_comm_error
          EXPORTING
            is_msg      = zcl_cilib_util_msg_tools=>get_msg_from_string( get_last_error_text( ) )
            ix_previous = lx_ex.
    ENDTRY.
  ENDMETHOD.

  METHOD get_last_error_text.
    DATA: lv_content_message TYPE string.

    DATA(lv_content) = mi_rest_client->get_response_entity( )->get_string_data( ).
    IF lv_content IS NOT INITIAL.
      TRY.
          lv_content_message = CAST zcl_cilib_util_json_object(
            zcl_cilib_util_json_parser=>create_from_string( lv_content )
          )->get_string( gc_error_message_attribute ).
        CATCH cx_sy_move_cast_error zcx_cilib_not_found.
          TRY.
              lv_content_message = CAST zcl_cilib_util_json_object(
                zcl_cilib_util_json_parser=>create_from_string( lv_content )
              )->get_string( gc_error_message_attribute2 ).
            CATCH cx_sy_move_cast_error zcx_cilib_not_found ##NO_HANDLER.
          ENDTRY.
      ENDTRY.
    ENDIF.

    mi_http_client->get_last_error( IMPORTING message = DATA(lv_http_message) ).

    rv_text = |{ lv_content_message } { lv_http_message }|.
  ENDMETHOD.

  METHOD zif_cilib_host~get_repo_name_from_url.
    CONSTANTS: lc_git_suffix_pattern TYPE string VALUE `^.*(\.git)$`.

    DATA(lo_url) = NEW zcl_cilib_http_url( iv_url ).
    DATA(lv_path) = lo_url->get_path( ).

    IF lv_path(1) = '/'.
      SHIFT lv_path LEFT BY 1 PLACES.
    ENDIF.

    CONDENSE lv_path.

    DATA(lo_regex) = NEW cl_abap_regex( lc_git_suffix_pattern ).
    DATA(lo_matcher) = lo_regex->create_matcher( text = lv_path ).
    IF lo_matcher->match( ) = abap_true.
      REPLACE SECTION OFFSET lo_matcher->get_offset( 1 ) LENGTH lo_matcher->get_length( 1 ) OF lv_path WITH space.
    ENDIF.

    rv_repository = condense( lv_path ).
  ENDMETHOD.

  METHOD authenticate_if_needed.
    IF zif_cilib_host~mv_is_authenticated = abap_false ##TODO. " Is 'lazy authentication' a good idea?
      zif_cilib_host~authenticate( ).
    ENDIF.
  ENDMETHOD.

  METHOD zif_cilib_host~get_config.
    ro_config = mo_config.
  ENDMETHOD.

  METHOD zif_cilib_host~get_host_path.
    rv_host_path = mv_host_path.
  ENDMETHOD.

  METHOD zif_cilib_host~create_wiki_page.
    DATA: lr_request_data TYPE REF TO data.
    " https://docs.gitlab.com/ce/api/wikis.html#create-a-new-wiki-page

    authenticate_if_needed( ).

    TRY.
        DATA(lv_path) = NEW zcl_cilib_http_path_builder( gc_api_base_path
          )->append_path_component( gc_endpoints-projects
          )->append_escaped_path_component( iv_repository
          )->append_path_component( gc_project_subpaths-wikis
          )->build( ).

        mi_rest_client->set_request_header( iv_name = if_http_header_fields_sap=>request_uri iv_value = lv_path ).
        mi_rest_client->set_request_header(
          iv_name  = if_http_header_fields=>content_type
          iv_value = 'application/json'
        ).

        DATA(lo_entity) = mi_rest_client->create_request_entity( ).

        DATA(lo_struct_builder) = NEW zcl_cilib_util_struct_builder( ).
        IF iv_format IS NOT INITIAL.
          lo_struct_builder->add_string( iv_key = gc_wiki_page_attributes-format iv_value = iv_format ).
        ENDIF.
        lo_struct_builder->add_string(
          iv_key   = gc_wiki_page_attributes-content
          iv_value = iv_content
        ).
        lo_struct_builder->add_string(
          iv_key   = gc_wiki_page_attributes-title
          iv_value = cl_http_utility=>escape_html( iv_title )
        ).
        lo_struct_builder->add_string(
          iv_key   = gc_wiki_page_attributes-name
          iv_value = cl_http_utility=>escape_html( iv_page_name )
        ).

        lo_entity->set_string_data( lo_struct_builder->get_json( ) ).

        mi_rest_client->post( lo_entity ).
        DATA(lv_status) = mi_rest_client->get_status( ).

        IF lv_status = 404.
          RAISE EXCEPTION TYPE zcx_cilib_not_found
            EXPORTING
              is_textid    = zcx_cilib_not_found=>gc_with_name_and_key
              iv_type_name = 'Repository'
              iv_key       = iv_repository.
        ELSEIF lv_status <> 201.
          RAISE EXCEPTION TYPE zcx_cilib_http_comm_error
            EXPORTING
              is_textid        = zcx_cilib_http_comm_error=>gc_code_and_message
              iv_response_code = lv_status
              iv_error_message = get_last_error_text( ).
        ENDIF.

      CATCH cx_rest_client_exception INTO DATA(lx_ex).
        RAISE EXCEPTION TYPE zcx_cilib_http_comm_error
          EXPORTING
            is_msg      = zcl_cilib_util_msg_tools=>get_msg_from_string( get_last_error_text( ) )
            ix_previous = lx_ex.
    ENDTRY.
  ENDMETHOD.

  METHOD zif_cilib_host~get_wiki_page.
    " https://docs.gitlab.com/ce/api/wikis.html#get-a-wiki-page

    authenticate_if_needed( ).

    TRY.
        DATA(lv_path) = NEW zcl_cilib_http_path_builder( gc_api_base_path
          )->append_path_component( gc_endpoints-projects
          )->append_escaped_path_component( iv_repository
          )->append_path_component( gc_project_subpaths-wikis
          )->append_escaped_path_component( iv_page_name
          )->build( ).

        mi_rest_client->set_request_header( iv_name = if_http_header_fields_sap=>request_uri iv_value = lv_path ).
        mi_rest_client->get( ).
        DATA(lv_status) = mi_rest_client->get_status( ).

        IF lv_status = 404.
          RAISE EXCEPTION TYPE zcx_cilib_not_found
            EXPORTING
              is_textid    = zcx_cilib_not_found=>gc_with_name_and_key
              iv_type_name = 'Wiki Page'
              it_keys      = VALUE #( ( iv_repository ) ( iv_page_name ) ).
        ELSEIF lv_status <> 200.
          RAISE EXCEPTION TYPE zcx_cilib_http_comm_error
            EXPORTING
              is_textid        = zcx_cilib_http_comm_error=>gc_code_and_message
              iv_response_code = lv_status
              iv_error_message = get_last_error_text( ).
        ENDIF.

        DATA(li_response) = mi_rest_client->get_response_entity( ).
        DATA(lo_json) = CAST zcl_cilib_util_json_object(
          zcl_cilib_util_json_parser=>create_from_xstring( li_response->get_binary_data( ) )
        ).

        rs_page = VALUE #(
          name    = lo_json->get_string( gc_wiki_page_attributes-name )
          format  = lo_json->get_string( gc_wiki_page_attributes-format )
          title   = lo_json->get_string( gc_wiki_page_attributes-title )
          content = lo_json->get_string( iv_name                     = gc_wiki_page_attributes-content
                                         iv_replace_unicode_entities = abap_true )
        ).

      CATCH cx_rest_client_exception INTO DATA(lx_ex).
        RAISE EXCEPTION TYPE zcx_cilib_http_comm_error
          EXPORTING
            is_msg      = zcl_cilib_util_msg_tools=>get_msg_from_string( get_last_error_text( ) )
            ix_previous = lx_ex.
    ENDTRY.
  ENDMETHOD.

  METHOD zif_cilib_host~get_wiki_pages.
    " https://docs.gitlab.com/ce/api/wikis.html#list-wiki-pages

    authenticate_if_needed( ).

    TRY.
        DATA(lv_path) = NEW zcl_cilib_http_path_builder( gc_api_base_path
          )->append_path_component( gc_endpoints-projects
          )->append_escaped_path_component( iv_repository
          )->append_path_component( gc_project_subpaths-wikis
          )->build( ).

        mi_rest_client->set_request_header( iv_name = if_http_header_fields_sap=>request_uri iv_value = lv_path ).
        mi_rest_client->get( ).
        DATA(lv_status) = mi_rest_client->get_status( ).

        IF lv_status = 404.
          RAISE EXCEPTION TYPE zcx_cilib_not_found
            EXPORTING
              is_textid    = zcx_cilib_not_found=>gc_with_name_and_key
              iv_type_name = 'Repository'
              iv_key       = iv_repository.
        ELSEIF lv_status <> 200.
          RAISE EXCEPTION TYPE zcx_cilib_http_comm_error
            EXPORTING
              is_textid        = zcx_cilib_http_comm_error=>gc_code_and_message
              iv_response_code = lv_status
              iv_error_message = get_last_error_text( ).
        ENDIF.

        DATA(li_response) = mi_rest_client->get_response_entity( ).
        DATA(lo_json) = CAST zcl_cilib_util_json_array(
          zcl_cilib_util_json_parser=>create_from_xstring( li_response->get_binary_data( ) )
        ).

        DO lo_json->get_count( ) TIMES.
          DATA(lo_child) = CAST zcl_cilib_util_json_object( lo_json->get_element_at( sy-index ) ).
          INSERT VALUE #(
            name   = lo_child->get_string( gc_wiki_page_attributes-name )
            format = lo_child->get_string( gc_wiki_page_attributes-format )
            title  = lo_child->get_string( gc_wiki_page_attributes-title )
          ) INTO TABLE rt_pages.
        ENDDO.

      CATCH cx_rest_client_exception INTO DATA(lx_ex).
        RAISE EXCEPTION TYPE zcx_cilib_http_comm_error
          EXPORTING
            is_msg      = zcl_cilib_util_msg_tools=>get_msg_from_string( get_last_error_text( ) )
            ix_previous = lx_ex.
    ENDTRY.
  ENDMETHOD.

  METHOD zif_cilib_host~update_wiki_page.
    " https://docs.gitlab.com/ce/api/wikis.html#edit-an-existing-wiki-page

    authenticate_if_needed( ).

    TRY.
        DATA(lv_path) = NEW zcl_cilib_http_path_builder( gc_api_base_path
          )->append_path_component( gc_endpoints-projects
          )->append_escaped_path_component( iv_repository
          )->append_path_component( gc_project_subpaths-wikis
          )->append_escaped_path_component( iv_page_name
          )->build( ).

        mi_rest_client->set_request_header( iv_name = if_http_header_fields_sap=>request_uri iv_value = lv_path ).
        mi_rest_client->set_request_header(
          iv_name  = if_http_header_fields=>content_type
          iv_value = 'application/json'
        ).

        DATA(lo_entity) = mi_rest_client->create_request_entity( ).

        DATA(lo_struct_builder) = NEW zcl_cilib_util_struct_builder( ).
        IF iv_format IS NOT INITIAL.
          lo_struct_builder->add_string( iv_key = gc_wiki_page_attributes-format iv_value = iv_format ).
        ENDIF.
        IF iv_content IS SUPPLIED.
          lo_struct_builder->add_string(
            iv_key   = gc_wiki_page_attributes-content
            iv_value = iv_content
          ).
        ENDIF.
        IF iv_title IS SUPPLIED.
          lo_struct_builder->add_string(
            iv_key   = gc_wiki_page_attributes-title
            iv_value = cl_http_utility=>escape_html( iv_title )
          ).
        ENDIF.
        lo_struct_builder->add_string(
          iv_key   = gc_wiki_page_attributes-name
          iv_value = cl_http_utility=>escape_html( iv_page_name )
        ).

        lo_entity->set_string_data( lo_struct_builder->get_json( ) ).

        mi_rest_client->put( lo_entity ).
        DATA(lv_status) = mi_rest_client->get_status( ).

        IF lv_status = 404.
          RAISE EXCEPTION TYPE zcx_cilib_not_found
            EXPORTING
              is_textid    = zcx_cilib_not_found=>gc_with_name_and_key
              iv_type_name = 'Wiki Page'
              it_keys      = VALUE #( ( iv_repository ) ( iv_page_name ) ).
        ELSEIF lv_status <> 200.
          RAISE EXCEPTION TYPE zcx_cilib_http_comm_error
            EXPORTING
              is_textid        = zcx_cilib_http_comm_error=>gc_code_and_message
              iv_response_code = lv_status
              iv_error_message = get_last_error_text( ).
        ENDIF.

      CATCH cx_rest_client_exception INTO DATA(lx_ex).
        RAISE EXCEPTION TYPE zcx_cilib_http_comm_error
          EXPORTING
            is_msg      = zcl_cilib_util_msg_tools=>get_msg_from_string( get_last_error_text( ) )
            ix_previous = lx_ex.
    ENDTRY.
  ENDMETHOD.

  METHOD zif_cilib_host~delete_wiki_page.
    " https://docs.gitlab.com/ce/api/wikis.html#delete-a-wiki-page

    authenticate_if_needed( ).

    TRY.
        DATA(lv_path) = NEW zcl_cilib_http_path_builder( gc_api_base_path
          )->append_path_component( gc_endpoints-projects
          )->append_escaped_path_component( iv_repository
          )->append_path_component( gc_project_subpaths-wikis
          )->append_escaped_path_component( iv_page_name
          )->build( ).

        mi_rest_client->set_request_header( iv_name = if_http_header_fields_sap=>request_uri iv_value = lv_path ).
        mi_rest_client->delete( ).
        DATA(lv_status) = mi_rest_client->get_status( ).

        IF lv_status = 404.
          RAISE EXCEPTION TYPE zcx_cilib_not_found
            EXPORTING
              is_textid    = zcx_cilib_not_found=>gc_with_name_and_key
              iv_type_name = 'Wiki Page'
              it_keys      = VALUE #( ( iv_repository ) ( iv_page_name ) ).
        ELSEIF lv_status <> 204.
          RAISE EXCEPTION TYPE zcx_cilib_http_comm_error
            EXPORTING
              is_textid        = zcx_cilib_http_comm_error=>gc_code_and_message
              iv_response_code = lv_status
              iv_error_message = get_last_error_text( ).
        ENDIF.

      CATCH cx_rest_client_exception INTO DATA(lx_ex).
        RAISE EXCEPTION TYPE zcx_cilib_http_comm_error
          EXPORTING
            is_msg      = zcl_cilib_util_msg_tools=>get_msg_from_string( get_last_error_text( ) )
            ix_previous = lx_ex.
    ENDTRY.
  ENDMETHOD.

  METHOD zif_cilib_host~get_labels_for_pull_request.
    " https://docs.gitlab.com/ce/api/merge_requests.html

    authenticate_if_needed( ).

    TRY.
        DATA(lv_path) = NEW zcl_cilib_http_path_builder( gc_api_base_path
          )->append_path_component( gc_endpoints-projects
          )->append_escaped_path_component( iv_repository
          )->append_path_component( gc_project_subpaths-merge_requests
          )->append_path_component( iv_pull_request
          )->build( ).

        mi_rest_client->set_request_header( iv_name = if_http_header_fields_sap=>request_uri iv_value = lv_path ).
        mi_rest_client->get( ).
        DATA(lv_status) = mi_rest_client->get_status( ).

        IF lv_status = 404.
          RAISE EXCEPTION TYPE zcx_cilib_not_found
            EXPORTING
              is_textid    = zcx_cilib_not_found=>gc_with_name_and_key
              iv_type_name = 'Repository'
              iv_key       = iv_repository.
        ELSEIF lv_status <> 200.
          RAISE EXCEPTION TYPE zcx_cilib_http_comm_error
            EXPORTING
              is_textid        = zcx_cilib_http_comm_error=>gc_code_and_message
              iv_response_code = lv_status
              iv_error_message = get_last_error_text( ).
        ENDIF.

        DATA(li_response) = mi_rest_client->get_response_entity( ).

        " Attribute first_deployed_to_production_at exceeds to maximum ABAP structure component name limit of 30
        " (abap_max_comp_name_ln) with causes /ui2/cl_json to silently fail (!?!?).
        DATA(lv_response) = li_response->get_string_data( ).
        REPLACE FIRST OCCURRENCE OF 'first_deployed_to_production_at' IN lv_response WITH 'fdtpa'.

        DATA(lo_json) = CAST zcl_cilib_util_json_object(
          zcl_cilib_util_json_parser=>create_from_string( lv_response )
        ).

        DATA(lo_label_array) = lo_json->get_array( gc_merge_request_attributes-labels ).
        DO lo_label_array->get_count( ) TIMES.
          APPEND CAST zcl_cilib_util_json_value(
            lo_label_array->get_element_at( sy-index )
          )->as_string( ) TO rt_labels.
        ENDDO.

      CATCH cx_rest_client_exception INTO DATA(lx_ex).
        RAISE EXCEPTION TYPE zcx_cilib_http_comm_error
          EXPORTING
            is_msg      = zcl_cilib_util_msg_tools=>get_msg_from_string( get_last_error_text( ) )
            ix_previous = lx_ex.
    ENDTRY.
  ENDMETHOD.

  METHOD zif_cilib_host~set_labels_for_pull_request.
    " https://docs.gitlab.com/ee/api/merge_requests.html#update-mr

    authenticate_if_needed( ).

    TRY.
        DATA(lv_path) = NEW zcl_cilib_http_path_builder( gc_api_base_path
          )->append_path_component( gc_endpoints-projects
          )->append_escaped_path_component( iv_repository
          )->append_path_component( gc_project_subpaths-merge_requests
          )->append_path_component( iv_pull_request
          )->build( ).

        mi_rest_client->set_request_header( iv_name = if_http_header_fields_sap=>request_uri iv_value = lv_path ).
        mi_rest_client->set_request_header(
          iv_name  = if_http_header_fields=>content_type
          iv_value = 'application/json'
        ).

        DATA(lo_entity) = mi_rest_client->create_request_entity( ).

        DATA(lv_json) = NEW zcl_cilib_util_struct_builder(
          )->add_string( iv_key = gc_merge_request_put_attrs-id iv_value = iv_repository
          )->add_int( iv_key = gc_merge_request_put_attrs-merge_request_iid iv_value = iv_pull_request
          )->add_string(
               iv_key   = gc_merge_request_put_attrs-labels
               iv_value = concat_lines_of( table = it_labels sep = ',' ) " No need to escape spaces apparently
          )->get_json( ).

        lo_entity->set_string_data( lv_json ).

        mi_rest_client->put( lo_entity ).
        DATA(lv_status) = mi_rest_client->get_status( ).

        IF lv_status = 404.
          RAISE EXCEPTION TYPE zcx_cilib_not_found
            EXPORTING
              is_textid    = zcx_cilib_not_found=>gc_with_name_and_key
              iv_type_name = 'Pull Request'
              it_keys      = VALUE #( ( iv_repository ) ( CONV #( iv_pull_request ) ) ).
        ELSEIF lv_status <> 200.
          RAISE EXCEPTION TYPE zcx_cilib_http_comm_error
            EXPORTING
              is_textid        = zcx_cilib_http_comm_error=>gc_code_and_message
              iv_response_code = lv_status
              iv_error_message = get_last_error_text( ).
        ENDIF.

      CATCH cx_rest_client_exception INTO DATA(lx_ex).
        RAISE EXCEPTION TYPE zcx_cilib_http_comm_error
          EXPORTING
            is_msg      = zcl_cilib_util_msg_tools=>get_msg_from_string( get_last_error_text( ) )
            ix_previous = lx_ex.
    ENDTRY.
  ENDMETHOD.
ENDCLASS.
