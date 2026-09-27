{#
    Helpers for cross-source matching (data model v2, section 8.4).

    level_signature(title): the level words a normalized title contains, in a fixed order, as one
    string. A fuzzy pair is accepted only when both titles have the same signature, because the
    word that separates two roles usually comes last and a similarity score barely sees it:
    Jaro-Winkler scores "data analyst" against "data analyst intern" at 92.
#}
{% macro level_words() %}
    {{ return(['intern', 'internship', 'trainee', 'apprentice', 'assistant', 'associate', 'junior',
               'senior', 'lead', 'head', 'principal', 'manager', 'director', 'chief', 'deputy', 'vice']) }}
{% endmacro %}

{% macro level_signature(column) %}
    (
    {%- for w in level_words() %}
        iff(' ' || {{ column }} || ' ' like '% {{ w }} %', '{{ 'intern' if w == 'internship' else w }} ', '')
        {%- if not loop.last %} ||{% endif %}
    {%- endfor %}
    )
{% endmacro %}
